import Foundation
import AppKit
import ApplicationServices

/// GUI 自动化回退（Tier 3）：先用深链打开 Codex 对应对话，再粘贴指令并回车。
/// 依赖辅助功能权限（System Events）。
struct AppleScriptAutomation {
    static func sendContinue(threadId: String, command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // 1) 深链打开/切换到对应对话，并等待界面加载（大对话可能需要一点时间）
        if let url = URL(string: "codex://threads/\(threadId)") {
            NSWorkspace.shared.open(url)
        }
        Thread.sleep(forTimeInterval: 3.0)
        // 2) 激活 Codex（进程名为 ChatGPT）→ 点击输入框确保焦点 → 粘贴指令 → Cmd+Enter 发送
        //    关键：必须先点击输入框，否则 keystroke v 会粘贴到当前焦点（可能是对话列表）而静默失效
        let script = """
        set the clipboard to "\(escaped)"
        tell application id "com.openai.codex" to activate
        delay 2.0
        tell application "System Events"
            tell process "ChatGPT"
                set frontmost to true
                try
                    set win to front window
                    set p to position of win
                    set s to size of win
                    set cx to (item 1 of p) + (item 1 of s) / 2
                    set cy to (item 2 of p) + (item 2 of s) - 55
                    click at {cx, cy}
                end try
            end tell
            delay 0.6
            keystroke "v" using command down
            delay 0.5
            key code 36 using command down
        end tell
        """
        try runAppleScript(script)
    }

    static func activateApp() throws {
        try runAppleScript(#"tell application id "com.openai.codex" to activate"#)
    }

    /// 检测辅助功能权限
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    static func runAppleScript(_ script: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8) ?? "AppleScript 失败"
            throw JSONRPCError(code: -1, message: msg, data: nil)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 一次逻辑 continuation 的三态结果
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

/// 自动继续引擎，严格三层 fallback：
/// - Tier 1：Remote Control control socket（调用方传入的 primary 客户端）
/// - Tier 2：bundled codex app-server（stdio，lazy 启动，manager 独占持有）
/// - Tier 3：GUI/Accessibility（仅在前两层全部明确失败时进入）
///
/// ambiguous（结果未知）时先 reconciliation：确认已提交则视为成功；
/// 确认未提交才允许下一层；无法确认则保持 uncertain，等待后续轮询补查。
final class AutoContinueEngine {
    let codexHome: String
    private let manager: AppServerManager

    /// 已处理过的线程，避免重复继续（仅在明确成功或 reconciliation 确认后加入）
    private var handledThreads: Set<String> = []
    /// 提交结果未知的线程（threadId → clientUserMessageId），等待后续 reconciliation
    private var pendingReconciliations: [String: String] = [:]
    private let stateLock = NSLock()
    private var busyCount = 0

    var onLog: ((String, String) -> Void)?
    /// 需要用户在系统设置授权辅助功能时的回调（不自动弹设置，由 UI 引导）
    var onNeedAccessibility: (() -> Void)?
    /// 最近一次继续失败的原因
    private(set) var lastFailureReason: String?

    init(codexHome: String, manager: AppServerManager) {
        self.codexHome = codexHome
        self.manager = manager
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

    /// 是否有 continuation / reconciliation 正在进行（Tier 1 热切换需避开）
    var isBusy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return busyCount > 0
    }

    private func beginWork() {
        stateLock.lock(); busyCount += 1; stateLock.unlock()
    }

    private func endWork() {
        stateLock.lock(); busyCount -= 1; stateLock.unlock()
    }

    private func markHandled(_ threadId: String) {
        stateLock.lock(); handledThreads.insert(threadId); stateLock.unlock()
    }

    private func setPending(_ threadId: String, _ clientId: String?) {
        stateLock.lock()
        if let clientId {
            pendingReconciliations[threadId] = clientId
        } else {
            pendingReconciliations.removeValue(forKey: threadId)
        }
        stateLock.unlock()
    }

    // MARK: - 主入口

    /// 继续指定线程。返回是否确认成功。
    /// - Parameters:
    ///   - primaryClient: 当前已连接的 app-server 客户端（Tier 1 或在用 Tier 2），可为 nil
    ///   - threadId: 目标线程
    ///   - command: 注入的指令
    ///   - fallbackToGUI: 是否允许 Tier 3 GUI 自动化
    func continueThread(primaryClient: AppServerClient?, threadId: String, command: String, fallbackToGUI: Bool) async -> Bool {
        beginWork()
        defer { endWork() }
        lastFailureReason = nil

        // 整个逻辑尝试共用一个对账标记（仅追踪用途，非官方幂等键）
        let clientUserMessageId = "codexreset-\(UUID().uuidString.lowercased())"

        var lastError = "无可用通道"
        var definitiveFailure = false
        var uncertainPending = false

        // ── 第一层：当前客户端（Tier 1，或已在使用的 Tier 2）
        if let primary = primaryClient {
            if !primary.isOpen {
                lastError = "当前通道连接已断开"
                definitiveFailure = true
            } else {
                let outcome = await attemptContinuation(client: primary, threadId: threadId,
                                                        command: command, clientUserMessageId: clientUserMessageId)
                switch await resolveOutcome(outcome, client: primary, threadId: threadId,
                                           clientUserMessageId: clientUserMessageId) {
                case .confirmed:
                    return true
                case .definitive(let why):
                    lastError = why
                    definitiveFailure = true
                case .uncertainKept(let why):
                    lastError = why
                    uncertainPending = true
                }
            }
        }

        // ── 第二层：Tier 2 bundled app-server（lazy）：
        // 仅当第一层明确失败（或无可用客户端）时启动；存在未确认的 ambiguous 提交时不得再发送
        let primaryIsTier2 = primaryClient?.tier == .tier2OwnServer
        if !uncertainPending, primaryClient == nil || (!primaryIsTier2 && definitiveFailure) {
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
                    definitiveFailure = true
                case .uncertainKept(let why):
                    lastError = why
                    uncertainPending = true
                }
            } catch {
                // 明确没有提交成功
                lastError = "Tier 2 bundled app-server 不可用: \(error)"
                definitiveFailure = true
            }
        }

        // ── 第三层：GUI 自动化 —— 仅在前两层全部明确失败时进入；
        // 存在未确认的 ambiguous 提交时绝不发送第二份 prompt
        if fallbackToGUI && definitiveFailure && !uncertainPending {
            if AppleScriptAutomation.hasAccessibilityPermission() {
                do {
                    try AppleScriptAutomation.sendContinue(threadId: threadId, command: command)
                    onLog?("已通过 GUI 自动化发送「\(command)」（深链打开对话并粘贴）",
                           "Sent \"\(command)\" via GUI automation (deep-linked into the chat and pasted)")
                    markHandled(threadId)
                    return true
                } catch {
                    lastError = "GUI 自动化失败: \(error)"
                }
            } else {
                lastError = "辅助功能未授权，无法在 Codex 中输入。请在面板「辅助功能」状态点「授权」勾选本 App（若勾选过仍提示，请重新勾选一次）"
                onNeedAccessibility?()
            }
        }

        lastFailureReason = lastError
        if uncertainPending {
            onLog?("继续结果未知，已记录待对账：\(lastError)",
                   "Continuation outcome unknown; recorded for reconciliation: \(lastError)")
        } else {
            onLog?("继续失败：\(lastError)", "Continue failed: \(lastError)")
        }
        return false
    }

    // MARK: - 单层尝试

    private enum OutcomeResolution {
        case confirmed
        case definitive(String)
        case uncertainKept(String)
    }

    /// 处理单层通道的尝试结果：confirmed 直接成功；
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
                setPending(threadId, clientUserMessageId)
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

    /// reconciliation：确认某次 clientUserMessageId 是否真的进入了 thread。
    /// 只做读取；优先复用 preferred 客户端，其次重连 Tier 1（用后即关），最后用 Tier 2。
    private func reconcileSubmission(preferred: AppServerClient?, threadId: String, clientUserMessageId: String) async -> ReconciliationResult {
        if let preferred, preferred.isOpen {
            return await readTurnsForClient(client: preferred, threadId: threadId, clientUserMessageId: clientUserMessageId)
        }
        // 重连 Tier 1 只读（用后即关，不影响通道归属）
        if let probe = await manager.probeDesktopControl() {
            let c = probe.client
            defer { c.close() }
            return await readTurnsForClient(client: c, threadId: threadId, clientUserMessageId: clientUserMessageId)
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

    /// 对历史 uncertain 提交补查（每轮自动继续前调用）：
    /// 确认已提交 → 记为已处理；确认未提交 → 移出 pending（本轮可重发）；无法确认 → 保留
    func resolvePendingReconciliations() async {
        let snapshot: [(String, String)]
        stateLock.lock()
        snapshot = pendingReconciliations.map { ($0.key, $0.value) }
        stateLock.unlock()
        guard !snapshot.isEmpty else { return }

        beginWork()
        defer { endWork() }
        for (threadId, clientId) in snapshot {
            let result = await reconcileSubmission(preferred: nil, threadId: threadId, clientUserMessageId: clientId)
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
    }

    // MARK: - turn 监控

    /// 后台监控 turn 完成，完成后释放线程写锁（否则 Codex 桌面 app 无法打开该对话）
    private func monitorTurn(client: AppServerClient, threadId: String, turnId: String) {
        Task {
            await Self.waitTurnCompletion(client: client, threadId: threadId, turnId: turnId)
            try? await client.requestDict("thread/unsubscribe", params: ["threadId": threadId])
            onLog?("线程 \(threadId) 的 turn 已结束，已释放线程（Codex 可重新打开该对话）",
                   "Turn ended for thread \(threadId); thread released (Codex can reopen it)")
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
