import Foundation
import AppKit

/// 一次逻辑 continuation 的三态结果（Tier 2 RPC 通道层面）
enum ContinuationOutcome {
    /// 服务端已接受（turn.id 非空且 status 为 inProgress/completed）
    case confirmed(TurnStartResult)
    /// 明确失败：确定没有提交成功，可进入下一层
    case definitiveFailure(String)
    /// 结果未知：请求可能已提交，必须先 reconciliation，禁止直接重发
    case uncertain(String)
}

/// reconciliation（对账）结果
enum ReconciliationResult {
    case found(turnId: String)
    /// 连续多次成功读取后确认未进入 thread
    case absent
    /// 无法完成对账
    case unreadable(String)
}

/// 待补查的提交：GUI 提交用本地 SQLite 回执对账；RPC 提交用 thread/turns/list 对账
private enum PendingSubmission {
    case gui(command: String, baseline: SubmissionBaseline)
    case rpc(clientUserMessageId: String)
}

/// 自动继续引擎，严格两层 fallback：
/// - Tier 1：Codex Desktop GUI 自动化（deep link → AX 聚焦 composer → 粘贴提交 → SQLite 回执确认）
/// - Tier 2：bundled codex app-server（stdio，lazy 启动，manager 独占持有）
///
/// 硬约束：GUI Tier 1 对某 thread 的尝试在确认完成前，绝不允许 Tier 2 对同一 thread 做任何写操作
/// （engine 内顺序执行保证；delivered=true / uncertain 时直接返回，不落入 Tier 2）。
/// ambiguous（结果未知）时先 reconciliation：确认已提交则视为成功；
/// 确认未提交才允许重试；无法确认则保持 pending，等待后续轮询补查。
final class AutoContinueEngine {
    let codexHome: String
    private let manager: AppServerManager
    private let reader: SQLiteReader

    /// 已处理过的线程，避免重复继续（仅在明确成功或 reconciliation 确认后加入）
    private var handledThreads: Set<String> = []
    /// 提交结果未知的线程（threadId → 待补查提交），等待后续 reconciliation
    private var pendingReconciliations: [String: PendingSubmission] = [:]
    private let stateLock = NSLock()
    private var busyCount = 0
    /// 正在监控运行中 turn 的 monitor 任务数（server 存活判据之一）
    private var activeMonitors = 0

    var onLog: ((String, String) -> Void)?
    /// 需要用户在系统设置授权辅助功能时的回调（不自动弹设置，由 UI 引导）
    var onNeedAccessibility: (() -> Void)?
    /// 最近一次继续失败的原因
    private(set) var lastFailureReason: String?

    /// GUI Tier 1 发送器。测试可注入 fake；nil = 使用真实 GUIContinuationController。
    var guiSender: ((String, String) -> GUIContinuationResult)?

    /// GUI pending 补查超时：超时仍无落盘记录则视为「未提交」移除 pending。
    /// 本地 SQLite 投影延迟为秒级，10 分钟足够保守。
    private let guiPendingTimeoutMs = 10 * 60 * 1000

    init(codexHome: String, manager: AppServerManager) {
        self.codexHome = codexHome
        self.manager = manager
        self.reader = SQLiteReader(codexHome: codexHome)
    }

    // MARK: - 状态查询

    func alreadyHandled(_ threadId: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return handledThreads.contains(threadId)
    }

    func isPendingReconciliation(_ threadId: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return pendingReconciliations[threadId] != nil
    }

    /// 是否有 continuation / reconciliation 正在进行
    var isBusy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return busyCount > 0
    }

    private func beginWork() {
        stateLock.lock(); busyCount += 1; stateLock.unlock()
    }

    private func endWork() {
        stateLock.lock(); busyCount -= 1
        let idle = busyCount == 0 && activeMonitors == 0 && pendingReconciliations.isEmpty
        stateLock.unlock()
        recycleServerIfIdle(idle)
    }

    /// app-server 生命周期（用户裁定）：只有「确有 turn 在运行 / 确有对账待查」才允许存活；
    /// 尝试明确失败、turn 全部结束、对账全部了结时当场回收，绝不留僵尸进程。
    /// 回收同时会断开面板用量通道，由下一轮 30s 轮询按需 lazy 重建，属预期行为。
    private func recycleServerIfIdle(_ idle: Bool) {
        guard idle else { return }
        manager.stopOwnServer()
        onLog?("app-server 空闲已回收（无运行中 turn、无待查提交）", "Idle app-server recycled (no running turn, no pending submission)")
    }

    private func markHandled(_ threadId: String) {
        stateLock.lock(); handledThreads.insert(threadId); stateLock.unlock()
    }

    private func setPending(_ threadId: String, _ pending: PendingSubmission?) {
        stateLock.lock()
        pendingReconciliations[threadId] = pending
        stateLock.unlock()
    }

    // MARK: - 主入口

    /// 继续指定线程。返回是否确认成功。
    /// - Parameters:
    ///   - threadId: 目标线程
    ///   - command: 注入的指令
    ///   - allowGUI: 是否允许 Tier 1 GUI 自动化（无头模式传 false）
    func continueThread(threadId: String, command: String, allowGUI: Bool) async -> Bool {
        beginWork()
        defer { endWork() }
        lastFailureReason = nil

        // 整个逻辑尝试共用一个对账标记（仅追踪用途，非官方幂等键）
        let clientUserMessageId = "codexreset-\(UUID().uuidString.lowercased())"

        var lastError = "无可用通道"

        // ── Tier 1：GUI 自动化。delivered=true / uncertain 时绝不落到 Tier 2（防重复 turn）
        if allowGUI {
            let result: GUIContinuationResult?
            if let guiSender {
                // 测试注入：fake 发送器不受本机辅助功能权限状态影响
                result = guiSender(threadId, command)
            } else if AppleScriptAutomation.hasAccessibilityPermission() {
                let gui = GUIContinuationController(codexHome: codexHome)
                gui.onLog = { [weak self] zh, en in self?.onLog?(zh, en) }
                result = gui.sendContinuation(threadId: threadId, command: command)
            } else {
                result = nil
                lastError = "辅助功能未授权，跳过 GUI Tier 1"
                onLog?(lastError, "Accessibility not granted; skipping GUI Tier 1")
                onNeedAccessibility?()
            }
            if let result {
                switch result {
                case .confirmedSuccess(let turnId):
                    onLog?("GUI Tier 1 回执确认：prompt 已进入 thread 并启动 turn \(turnId)",
                           "GUI Tier 1 receipt confirmed: prompt entered the thread and started turn \(turnId)")
                    markHandled(threadId)
                    return true
                case .confirmedFailure(let reason, delivered: true):
                    // Desktop 已收到 prompt（turn 执行失败 / 投递到错误 thread）：
                    // 禁止 Tier 2 重发，也不标已处理（允许用户确认后再次手动继续）
                    lastFailureReason = "GUI 已投递但未成功：\(reason)"
                    onLog?(lastFailureReason!, "GUI delivered but unsuccessful: \(reason)")
                    return false
                case .confirmedFailure(let reason, delivered: false):
                    // Desktop 未收到任何 prompt：Tier 2 可安全接管
                    lastError = "GUI Tier 1 未提交任何 prompt（\(reason)）"
                    onLog?(lastError, "GUI Tier 1 submitted nothing (\(reason))")
                case .uncertain(let reason, let baseline):
                    setPending(threadId, .gui(command: command, baseline: baseline))
                    lastFailureReason = "GUI Tier 1 结果未知（\(reason)），已记录待 DB 对账，禁止 Tier 2 重发"
                    onLog?(lastFailureReason!, "GUI Tier 1 outcome unknown (\(reason)); recorded for DB reconciliation, no Tier 2 resend")
                    return false
                }
            }
        }

        // ── Tier 2：bundled app-server（仅当 GUI 明确「未提交任何 prompt」时进入）
        do {
            let t2 = try manager.startOwnServer()
            if !t2.isInitialized {
                try await t2.initialize()
            }
            let outcome = await attemptContinuation(client: t2, threadId: threadId,
                                                    command: command, clientUserMessageId: clientUserMessageId)
            switch await resolveOutcome(outcome, client: t2, threadId: threadId,
                                        clientUserMessageId: clientUserMessageId) {
            case .confirmed:
                return true
            case .definitive(let why):
                lastError = why
            case .uncertainKept(let why):
                lastFailureReason = why
                onLog?("继续结果未知，已记录待对账：\(why)",
                       "Continuation outcome unknown; recorded for reconciliation: \(why)")
                return false
            }
        } catch {
            // 明确没有提交成功
            lastError = "Tier 2 bundled app-server 不可用: \(error)"
        }

        lastFailureReason = lastError
        onLog?("继续失败：\(lastError)", "Continue failed: \(lastError)")
        return false
    }

    // MARK: - 单层尝试

    private enum OutcomeResolution {
        case confirmed
        case definitive(String)
        case uncertainKept(String)
    }

    /// 处理 Tier 2 通道的尝试结果：confirmed 直接成功；
    /// uncertain 先 reconciliation（确认已提交→成功；确认未提交→明确失败；无法对账→保持 uncertain）
    private func resolveOutcome(_ outcome: ContinuationOutcome, client: AppServerClient, threadId: String,
                                clientUserMessageId: String) async -> OutcomeResolution {
        switch outcome {
        case .confirmed(let result):
            onLog?("已通过 \(client.tier.name) 提交，turn 状态: \(result.status)",
                   "Submitted via \(client.tier.name); turn status: \(result.status)")
            monitorTurn(client: client, threadId: threadId, turnId: result.turnId)
            markHandled(threadId)
            setPending(threadId, nil)
            return .confirmed

        case .definitiveFailure(let why):
            return .definitive("\(client.tier.name) 明确失败: \(why)")

        case .uncertain(let why):
            onLog?("\(client.tier.name) 提交结果未知（\(why)），开始 reconciliation…",
                   "\(client.tier.name) outcome unknown (\(why)); starting reconciliation…")
            let rec = await reconcileSubmission(preferred: client, threadId: threadId,
                                                clientUserMessageId: clientUserMessageId)
            switch rec {
            case .found(let turnId):
                onLog?("reconciliation 确认 prompt 已进入 thread（turn \(turnId)），禁止重复发送",
                       "Reconciliation confirmed the prompt entered the thread (turn \(turnId)); no resend")
                monitorTurn(client: client, threadId: threadId, turnId: turnId)
                markHandled(threadId)
                setPending(threadId, nil)
                return .confirmed
            case .absent:
                return .definitive("\(client.tier.name) 提交未生效（reconciliation 确认未进入 thread）: \(why)")
            case .unreadable(let err):
                setPending(threadId, .rpc(clientUserMessageId: clientUserMessageId))
                return .uncertainKept("结果未知且无法完成 reconciliation（\(err)）: \(why)")
            }
        }
    }

    /// 在指定客户端上执行 thread/resume + turn/start，并按协议语义返回三态结果
    private func attemptContinuation(client: AppServerClient, threadId: String, command: String, clientUserMessageId: String) async -> ContinuationOutcome {
        // 1) resume（excludeTurns: true：不把整段历史 hydrate 回本 App）
        do {
            _ = try await client.requestDict("thread/resume", params: ["threadId": threadId, "excludeTurns": true])
            onLog?("已 resume 线程 \(threadId)", "Resumed thread \(threadId)")
        } catch {
            // resume 只加载线程、不携带 prompt：失败可安全进入下一层；尽力释放可能持有的 writer 锁
            try? await client.requestDict("thread/unsubscribe", params: ["threadId": threadId])
            return .definitiveFailure("thread/resume 失败: \(error)")
        }

        // 2) turn/start：请求写出后未收到响应 = 结果未知（不得直接重发）
        do {
            let dict = try await client.requestDict("turn/start", params: [
                "threadId": threadId,
                "clientUserMessageId": clientUserMessageId,
                "input": [["type": "text", "text": command]]
            ])
            guard let result = TurnStartResult.parse(dict) else {
                // 响应已由服务端产生但结构异常：可能已提交 → 走 reconciliation
                return .uncertain("turn/start 响应结构异常")
            }
            if result.isAccepted {
                return .confirmed(result)
            }
            if result.status == "failed" || result.status == "interrupted" {
                let extra = result.errorMessage.map { "：\($0)" } ?? ""
                return .definitiveFailure("turn \(result.status)\(extra)")
            }
            return .uncertain("turn status=\(result.status)")
        } catch let e as RPCTransportError {
            // 请求已写出（或无法确定是否写出）但未收到响应
            return .uncertain("\(e)")
        } catch let e as JSONRPCError {
            // 服务端明确拒绝
            return .definitiveFailure("turn/start 被拒绝: \(e)")
        } catch {
            // transport 写出失败：请求未真正发出
            return .definitiveFailure("turn/start 发送失败: \(error)")
        }
    }

    // MARK: - reconciliation（只读）

    /// RPC reconciliation：确认某次 clientUserMessageId 是否真的进入了 thread。
    /// 只做读取；优先复用 preferred 客户端，其次用 Tier 2。
    private func reconcileSubmission(preferred: AppServerClient?, threadId: String, clientUserMessageId: String) async -> ReconciliationResult {
        if let preferred, preferred.isOpen {
            return await readTurnsForClient(client: preferred, threadId: threadId, clientUserMessageId: clientUserMessageId)
        }
        // Tier 2（manager 独占持有，退出时统一回收）
        if let t2 = try? manager.startOwnServer() {
            if !t2.isInitialized {
                _ = try? await t2.initialize()
            }
            return await readTurnsForClient(client: t2, threadId: threadId, clientUserMessageId: clientUserMessageId)
        }
        return .unreadable("无可用协议通道")
    }

    /// 连续多次读取最近 turns（刚提交的 turn 可能尚未持久化，短重试避开竞争窗口）
    private func readTurnsForClient(client: AppServerClient, threadId: String, clientUserMessageId: String) async -> ReconciliationResult {
        for attempt in 0..<3 {
            do {
                let dict = try await client.requestDict("thread/turns/list", params: [
                    "threadId": threadId,
                    "limit": 20,
                    "sortDirection": "desc",
                    "itemsView": "full"
                ])
                if let turnId = TurnPage(dict).turnId(matchingClientId: clientUserMessageId) {
                    return .found(turnId: turnId)
                }
                if attempt < 2 { try? await Task.sleep(nanoseconds: 2_500_000_000) }
            } catch {
                return .unreadable("\(error)")
            }
        }
        return .absent
    }

    // MARK: - 对账补查

    /// 对历史 uncertain 提交补查（每轮自动继续前调用）：
    /// 确认已提交 → 记为已处理；确认未提交 → 移出 pending（本轮可重发）；无法确认 → 保留
    func resolvePendingReconciliations() async {
        let snapshot: [(String, PendingSubmission)]
        stateLock.lock()
        snapshot = pendingReconciliations.map { ($0.key, $0.value) }
        stateLock.unlock()
        guard !snapshot.isEmpty else { return }

        beginWork()
        defer { endWork() }
        for (threadId, pending) in snapshot {
            switch pending {
            case .rpc(let clientId):
                await resolveRPCPending(threadId: threadId, clientUserMessageId: clientId)
            case .gui(let command, let baseline):
                resolveGUIPending(threadId: threadId, command: command, baseline: baseline)
            }
        }
    }

    /// RPC（Tier 2）pending：thread/turns/list 对账
    private func resolveRPCPending(threadId: String, clientUserMessageId: String) async {
        let result = await reconcileSubmission(preferred: nil, threadId: threadId, clientUserMessageId: clientUserMessageId)
        switch result {
        case .found(let turnId):
            onLog?("对账确认：thread \(threadId) 的上次提交已进入 thread（turn \(turnId)）",
                   "Reconciliation: the earlier submission for thread \(threadId) did enter the thread (turn \(turnId))")
            markHandled(threadId)
            setPending(threadId, nil)
        case .absent:
            onLog?("对账确认：thread \(threadId) 的上次提交未生效，本轮允许重发",
                   "Reconciliation: the earlier submission for thread \(threadId) never landed; resend allowed this round")
            setPending(threadId, nil)
        case .unreadable(let err):
            onLog?("对账未完成（\(err)），thread \(threadId) 保持等待，不重发",
                   "Reconciliation incomplete (\(err)); thread \(threadId) stays pending, no resend")
        }
    }

    /// GUI（Tier 1）pending：本地 SQLite 回执对账（只读；投影延迟秒级）
    private func resolveGUIPending(threadId: String, command: String, baseline: SubmissionBaseline) {
        guard let evidence = reader.findSubmissionEvidence(threadId: threadId, baseline: baseline, command: command) else {
            let elapsed = Int(Date().timeIntervalSince1970 * 1000) - baseline.attemptStartedAtMs
            if elapsed > guiPendingTimeoutMs {
                onLog?("GUI 提交 \(elapsed / 60000) 分钟后仍无落盘记录，视为未提交：移除 pending，允许下轮重发",
                       "No DB record after \(elapsed / 60000) min; treating as never submitted: pending cleared, resend allowed next round")
                setPending(threadId, nil)
            } else {
                onLog?("GUI 提交尚未落盘，继续等待对账（不重复发送）",
                       "GUI submission not yet visible in DB; keep waiting (no resend)")
            }
            return
        }
        let status = evidence.turnStatus
        if evidence.isNewTurn && (status == "inProgress" || status == "completed") {
            onLog?("对账确认：GUI 提交已进入 thread（turn \(evidence.turnId)，status \(status)），标记已处理",
                   "Reconciliation: GUI submission entered the thread (turn \(evidence.turnId), status \(status)); marked handled")
            markHandled(threadId)
            setPending(threadId, nil)
            return
        }
        if status == "failed" || status == "interrupted" {
            var msg = ""
            if let ej = evidence.turnErrorJson, let d = ej.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                msg = o["message"] as? String ?? ""
            }
            if msg.isEmpty { msg = evidence.turnErrorJson.map { String($0.prefix(200)) } ?? "" }
            onLog?("对账确认：GUI 提交已落盘但 turn \(status)（\(msg)）：移除 pending，不标记已处理，允许将来重试",
                   "Reconciliation: GUI submission landed but turn \(status) (\(msg)); pending cleared, not handled, retry allowed later")
            setPending(threadId, nil)
            return
        }
        if !evidence.isNewTurn {
            onLog?("对账异常：userMessage 落入已存在 turn（\(evidence.turnId)），保持 pending 等待下一轮",
                   "Reconciliation anomaly: userMessage landed in a pre-existing turn (\(evidence.turnId)); stays pending")
            return
        }
        onLog?("对账：turn \(evidence.turnId) 状态 \(status) 未决，保持 pending（不重复发送）",
               "Reconciliation: turn \(evidence.turnId) status \(status) undecided; stays pending (no resend)")
    }

    // MARK: - turn 监控

    /// 后台监控 turn 完成，完成后释放线程写锁（否则 Codex 桌面 app 无法打开该对话）；
    /// turn 结束且没有其它运行中任务时回收 app-server（不留闲置 server）
    private func monitorTurn(client: AppServerClient, threadId: String, turnId: String) {
        stateLock.lock(); activeMonitors += 1; stateLock.unlock()
        Task {
            await Self.waitTurnCompletion(client: client, threadId: threadId, turnId: turnId)
            try? await client.requestDict("thread/unsubscribe", params: ["threadId": threadId])
            onLog?("线程 \(threadId) 的 turn 已结束，已释放线程（Codex 可重新打开该对话）",
                   "Turn ended for thread \(threadId); thread released (Codex can reopen it)")
            stateLock.lock(); activeMonitors -= 1
            let idle = busyCount == 0 && activeMonitors == 0 && pendingReconciliations.isEmpty
            stateLock.unlock()
            recycleServerIfIdle(idle)
        }
    }

    /// 轮询 turn 状态，直到 completed/failed/interrupted（最多 6 小时）
    private static func waitTurnCompletion(client: AppServerClient, threadId: String, turnId: String) async {
        let deadline = Date().addingTimeInterval(6 * 3600)
        while Date() < deadline {
            do {
                let dict = try await client.requestDict("thread/turns/list", params: ["threadId": threadId])
                let page = TurnPage(dict)
                if let turn = page.turns.first(where: { ($0["id"] as? String) == turnId }),
                   let status = turn["status"] as? String,
                   status != "inProgress", status != "queued", status != "pending" {
                    return
                }
            } catch {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
}
