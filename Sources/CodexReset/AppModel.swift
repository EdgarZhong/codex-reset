import Foundation
import AppKit

/// 一条日志：同时保存中英文，展示时按当前语言渲染（切换语言后旧日志也会跟随切换）
struct LogEntry {
    let time: String
    let zh: String
    let en: String
    /// 按当前语言取展示文案
    var display: String { L(zh, en) }
}

/// 全局应用状态与编排：连接 app-server → 轮询用量 → 定位暂停线程 → 到点自动继续
@MainActor
final class AppModel: ObservableObject {
    @Published var connectionMode: String = "connecting"
    @Published var rateLimits: AccountRateLimits?
    @Published var lastError: String?
    /// 所有因用量暂停的对话（最新在前）
    @Published var pausedThreads: [PausedThread] = []
    /// 所有对话（含未暂停），可按项目勾选任意对话参与自动继续
    @Published var allThreads: [PausedThread] = []
    /// 勾选、需要在恢复后自动继续的对话
    @Published var selectedThreadIds: Set<String> = []
    @Published var logLines: [LogEntry] = []
    @Published var autoContinue: Bool {
        didSet { UserDefaults.standard.set(autoContinue, forKey: "autoContinue") }
    }
    @Published var continueCommand: String {
        didSet { UserDefaults.standard.set(continueCommand, forKey: "continueCommand") }
    }
    @Published var isWorking = false
    /// 语言设置：system / zh / en（切换后写回 UserDefaults 并通过 objectWillChange 触发界面刷新）
    @Published var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            // 默认指令跟随语言：仅当指令仍为内置默认值（继续/Continue）时自动同步切换，用户自定义指令不受影响
            if continueCommand == "继续" || continueCommand == "Continue" {
                continueCommand = L("继续", "Continue")
            }
        }
    }
    /// 本 App 是否已获得辅助功能授权（GUI Tier 1 通道所需；无参检测不弹窗）
    @Published var accessibilityAuthorized: Bool = false
    /// 5 小时窗口时间线（每次用量重置记录一个点）
    @Published var resetHistory: [UsageResetEvent] = []

    let codexHome: String
    let manager: AppServerManager
    private let reader: SQLiteReader
    private let engine: AutoContinueEngine
    /// 当前连接的 Tier 2 客户端（bundled app-server，manager 独占持有，退出时统一回收）
    private var client: AppServerClient?
    private var timer: Timer?
    /// 记录上一次是否处于「已到上限」状态，用于恢复检测
    private var wasLimited = false
    /// 上次等待恢复确认的原因（避免每 30s 重复刷日志）
    private var lastRecoveryWaitReason: String?

    init(codexHome: String = AppModel.defaultCodexHome()) {
        self.codexHome = codexHome
        self.manager = AppServerManager(codexHome: codexHome)
        self.reader = SQLiteReader(codexHome: codexHome)
        self.engine = AutoContinueEngine(codexHome: codexHome, manager: manager)
        self.autoContinue = UserDefaults.standard.object(forKey: "autoContinue") as? Bool ?? true
        self.continueCommand = UserDefaults.standard.string(forKey: "continueCommand") ?? L("继续", "Continue")
        self.language = UserDefaults.standard.string(forKey: "language") ?? "system"
        engine.onLog = { [weak self] zh, en in
            Task { @MainActor in self?.appendLog(zh, en) }
        }
        engine.onNeedAccessibility = { [weak self] in
            Task { @MainActor in self?.notifyNeedAccessibility() }
        }
        loadResetHistory()
    }

    nonisolated static func defaultCodexHome() -> String {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory() + "/.codex"
    }

    // MARK: - 启动

    func start() {
        appendLog("CodexReset 启动，CODEX_HOME=\(codexHome)", "CodexReset started, CODEX_HOME=\(codexHome)")
        // 暂停对话列表来自本地 sqlite，不依赖 app-server，立即加载
        refreshPausedThreads()
        refreshAllThreads()
        Task { await connectAndBegin() }
    }

    func connectAndBegin() async {
        manager.resolveRuntime()
        if let path = manager.runtimePath {
            let version = manager.runtimeVersion ?? L("未知版本", "unknown version")
            appendLog("Codex runtime：\(path)（\(version)）", "Codex runtime: \(path) (\(version))")
        } else {
            appendLog("未找到可用的 codex 可执行文件（可通过 CODEX_CLI_PATH 指定）",
                      "No usable codex binary found (set CODEX_CLI_PATH to override)")
        }
        await refreshChannelAndUsage()
        startPolling()
    }

    /// 无头查询：连接、读取用量与暂停线程并打印
    func runHeadlessQuery() async {
        await connectAndBegin()
        // 轮询等待用量返回（最多 20 秒）
        for _ in 0..<20 {
            if rateLimits != nil || connectionMode == "none" { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("mode=\(connectionMode)")
        print("lastError=\(lastError ?? "nil")")
        if let rl = rateLimits {
            print("plan=\(rl.rateLimits.planType ?? "?")")
            print("ordinaryUsageAllowed=\(rl.ordinaryUsageAllowed.map { String($0) } ?? "nil")")
            print("primary.usedPercent=\(rl.rateLimits.primary?.usedPercent ?? -1) resetsAt=\(rl.rateLimits.primary?.resetsAt ?? 0) windowMins=\(rl.rateLimits.primary?.windowDurationMins ?? 0)")
            print("secondary.usedPercent=\(rl.rateLimits.secondary?.usedPercent ?? -1) resetsAt=\(rl.rateLimits.secondary?.resetsAt ?? 0) windowMins=\(rl.rateLimits.secondary?.windowDurationMins ?? 0)")
            print("reached=\(rl.rateLimits.rateLimitReachedType ?? "nil") credits=\(rl.rateLimits.credits?.balance ?? "nil")")
        }
        for entry in logLines { print("log: [\(entry.time)] \(entry.display)") }
        refreshPausedThreads()
        print("pausedCount=\(pausedThreads.count)")
        for p in pausedThreads {
            print("pausedThread=\(p.threadId) | \(p.title) | \(p.cwd) | \(p.recoveryHint ?? "")")
        }
        manager.stopOwnServer()
    }

    /// 无头模式：连接后立即继续指定线程，打印结果（跳过 GUI Tier 1，直走 Tier 2）
    func runHeadlessContinue(threadId: String) async {
        await connectAndBegin()
        let ok = await engine.continueThread(
            threadId: threadId,
            command: continueCommand,
            allowGUI: false
        )
        print("continueResult=\(ok)")
        manager.stopOwnServer()
    }

    /// 退出：清理自起的 app-server 子进程
    func quit() {
        manager.stopOwnServer()
        NSApp.terminate(nil)
    }

    /// 收到终止信号时的清理（launchd 停止 / kill）
    func stopAndExit() {
        manager.stopOwnServer()
        exit(0)
    }

    private func startOwnServerFallback() async {
        do {
            let own = try manager.startOwnServer()
            client = own
            if !own.isInitialized {
                try await own.initialize()
            }
            connectionMode = "own-server"
            appendLog("已启动 bundled codex app-server（stdio，Tier 2）",
                      "Started the bundled codex app-server (stdio, Tier 2)")
        } catch {
            connectionMode = "none"
            manager.stopOwnServer()
            let zhMsg = "bundled app-server 启动失败: \(error)"
            let enMsg = "bundled app-server failed to start: \(error)"
            lastError = zhMsg
            appendLog(zhMsg, enMsg)
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    // MARK: - 刷新

    /// 刷新用量与暂停列表（暂停列表本地读取，不依赖 app-server 连接）
    func refreshNow() {
        refreshPausedThreads()
        // 全部对话列表同样定时刷新，对话标题保持最新（在 Codex 里重命名后自动跟上）
        refreshAllThreads()
        accessibilityAuthorized = AppleScriptAutomation.hasAccessibilityPermission()
        Task { await refreshChannelAndUsage() }
    }

    /// 通道维护 + 用量刷新：当前通道断开 → 重建（lazy 启动 Tier 2 bundled app-server）
    private func refreshChannelAndUsage() async {
        if let current = client, !current.isOpen {
            appendLog("app-server 通道已断开", "app-server channel closed")
            current.close()
            client = nil
            connectionMode = "none"
        }

        if client == nil {
            await startOwnServerFallback()
        }

        guard let client else { return }
        await refreshRateLimits(client: client)
    }

    private func refreshRateLimits(client: AppServerClient) async {
        do {
            let dict = try await client.requestDict("account/rateLimits/read")
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let parsed = try? JSONDecoder().decode(AccountRateLimits.self, from: data) else {
                lastError = "用量响应解析失败"
                appendLog("用量响应解析失败", "Failed to decode usage response")
                return
            }
            applyRateLimits(parsed)
        } catch {
            lastError = "读取用量失败: \(error)"
            appendLog("读取用量失败: \(error)", "Failed to read usage: \(error)")
        }
    }

    private func applyRateLimits(_ rl: AccountRateLimits) {
        rateLimits = rl
        lastError = nil
        checkRecovery(rl)
        trackWindowReset(rl)
    }

    // MARK: - 用量历史（5h 窗口时间线）

    /// 上次观测到的 primary 窗口重置时间（Unix 秒）
    private var lastResetsAt: Int?

    /// 检测 5 小时窗口重置：resetsAt 变化即记录一个新窗口点
    private func trackWindowReset(_ rl: AccountRateLimits) {
        guard let primary = rl.rateLimits.primary, let resetsAt = primary.resetsAt else { return }
        guard lastResetsAt != resetsAt else { return }
        // 窗口起点 = 下次重置时间 - 窗口时长（优先用服务端给出的 windowDurationMins，缺失才回退 300 分钟）
        let windowMins = primary.windowDurationMins ?? 300
        let windowStart = resetsAt - windowMins * 60
        appendResetEvent(windowStart: windowStart, nextResetAt: resetsAt, usedPercent: Double(primary.usedPercent))
        lastResetsAt = resetsAt
    }

    /// 追加一个窗口点并持久化（保留最近 200 条）
    private func appendResetEvent(windowStart: Int, nextResetAt: Int, usedPercent: Double) {
        let evt = UsageResetEvent(
            windowStart: Date(timeIntervalSince1970: TimeInterval(windowStart)),
            nextResetAt: Date(timeIntervalSince1970: TimeInterval(nextResetAt)),
            usedPercent: usedPercent
        )
        resetHistory.insert(evt, at: 0)
        if resetHistory.count > 200 {
            resetHistory.removeLast(resetHistory.count - 200)
        }
        saveResetHistory()
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        appendLog("记录用量窗口：\(f.string(from: evt.windowStart)) 开始，下次重置 \(f.string(from: evt.nextResetAt))（用量 \(Int(usedPercent))%）",
                  "Recorded usage window: start \(f.string(from: evt.windowStart)), next reset \(f.string(from: evt.nextResetAt)) (usage \(Int(usedPercent))%)")
    }

    private func loadResetHistory() {
        guard let data = UserDefaults.standard.data(forKey: "usageResetHistory"),
              let history = try? JSONDecoder().decode([UsageResetEvent].self, from: data) else {
            return
        }
        resetHistory = history
    }

    private func saveResetHistory() {
        if let data = try? JSONEncoder().encode(resetHistory) {
            UserDefaults.standard.set(data, forKey: "usageResetHistory")
        }
    }

    /// 刷新暂停对话列表（不自动勾选；勾选完全由用户控制）
    func refreshPausedThreads() {
        pausedThreads = reader.usageLimitedThreads()
    }

    /// 刷新「全部对话」列表（面板每次打开时调用）
    func refreshAllThreads() {
        allThreads = reader.allThreads()
    }

    /// 所有勾选的对话（暂停 + 全部，按 threadId 去重，保持最新在前）
    private func selectedTargets() -> [PausedThread] {
        var seen = Set<String>()
        var result: [PausedThread] = []
        for t in pausedThreads where selectedThreadIds.contains(t.threadId) {
            if seen.insert(t.threadId).inserted { result.append(t) }
        }
        for t in allThreads where selectedThreadIds.contains(t.threadId) {
            if seen.insert(t.threadId).inserted { result.append(t) }
        }
        return result
    }

    /// 用量恢复检测 + 自动继续。
    /// 恢复许可唯一依据是 QuotaRecovery（ordinaryUsageAllowed == true 且无 reached/spendControl 标记）；
    /// usedPercent / resetsAt 只用于展示，不作为自动发送的许可。
    private func checkRecovery(_ rl: AccountRateLimits) {
        let primary = rl.rateLimits.primary
        let isLimited = (rl.rateLimits.rateLimitReachedType != nil &&
                         rl.rateLimits.rateLimitReachedType != "none") ||
                        (primary?.usedPercent ?? 0) >= 100

        if wasLimited {
            let decision = QuotaRecovery.decision(rl)
            if decision.isAllowed {
                appendLog("检测到用量恢复！usedPercent=\(primary?.usedPercent ?? -1)%，ordinaryUsageAllowed=true",
                          "Usage recovered! usedPercent=\(primary?.usedPercent ?? -1)%, ordinaryUsageAllowed=true")
                notify(title: "Codex 用量已恢复", body: "正在自动继续上次暂停的对话…")
                lastRecoveryWaitReason = nil
                wasLimited = false
                Task { await autoContinueIfNeeded() }
            } else if isLimited {
                lastRecoveryWaitReason = nil
            } else {
                // 窗口已到期但后端未明确肯定恢复：保持等待，继续轮询，不得据 usedPercent/resetsAt 宣布恢复
                let reason = decision.reasonText
                if lastRecoveryWaitReason != reason {
                    appendLog("用量窗口已到期，但后端未确认恢复（\(reason)），继续轮询…",
                              "Window expired but recovery not confirmed by backend (\(reason)); keep polling…")
                    lastRecoveryWaitReason = reason
                }
            }
        } else {
            wasLimited = isLimited
        }
    }

    /// 到点自动继续：对所有勾选的对话（暂停 + 全部）逐个发送「继续」
    func autoContinueIfNeeded() async {
        guard autoContinue else { return }
        refreshPausedThreads()
        let targets = selectedTargets()
        guard !targets.isEmpty else {
            appendLog("没有勾选的对话，跳过自动继续", "No chats selected; skipping auto-continue")
            return
        }
        // 恢复许可：ordinaryUsageAllowed == true 且无 reached/spendControl 标记
        guard let rl = rateLimits else {
            appendLog("尚无额度数据，无法确认恢复，等待下一次轮询…", "No usage data yet; waiting for the next poll…")
            return
        }
        let decision = QuotaRecovery.decision(rl)
        guard decision.isAllowed else {
            appendLog("未获得恢复许可（\(decision.reasonText)），等待中…",
                      "Recovery not permitted (\(decision.reasonText)); waiting…")
            return
        }
        // 先补查历史 uncertain 提交；确认结果后才允许新一轮发送
        await engine.resolvePendingReconciliations()
        for paused in targets {
            if engine.alreadyHandled(paused.threadId) {
                appendLog("已处理过「\(paused.title)」，跳过", "Already handled \"\(paused.title)\"; skipping")
                continue
            }
            if engine.isPendingReconciliation(paused.threadId) {
                appendLog("「\(paused.title)」上次提交结果未知且未确认，跳过以免重复发送",
                          "\"\(paused.title)\" has an unconfirmed earlier submission; skipping to avoid duplicates")
                continue
            }
            await continueOne(paused: paused, auto: true)
        }
    }

    /// 对单个对话执行继续（Tier 1 GUI → Tier 2 bundled app-server）
    private func continueOne(paused: PausedThread, auto: Bool) async {
        isWorking = true
        appendLog("\(auto ? "自动" : "手动")继续：\(paused.title)",
                  "\(auto ? "Auto" : "Manual") continue: \(paused.title)")
        let ok = await engine.continueThread(
            threadId: paused.threadId,
            command: continueCommand,
            allowGUI: true
        )
        isWorking = false
        if ok {
            notify(title: "Codex 已继续", body: "已对「\(paused.title)」发送「\(continueCommand)」")
        } else {
            // 手动/自动失败都要明确反馈（辅助功能引导走 engine.onNeedAccessibility 通知，不自动弹系统设置）
            let reason = engine.lastFailureReason ?? "未知原因"
            notify(title: "继续失败", body: "「\(paused.title)」\n\(reason)")
        }
    }

    /// 手动立即继续：对所有勾选的对话（暂停 + 全部）执行继续（无额度许可门，用户显式点击即授权）
    func manualContinue() async {
        refreshPausedThreads()
        let targets = selectedTargets()
        guard !targets.isEmpty else {
            appendLog("没有勾选的对话", "No chats selected")
            return
        }
        // 同样先补查 uncertain 提交；未确认前不发送第二份 prompt
        await engine.resolvePendingReconciliations()
        for paused in targets {
            if engine.isPendingReconciliation(paused.threadId) {
                appendLog("「\(paused.title)」上次提交结果未知且未确认，已跳过（避免重复发送）",
                          "\"\(paused.title)\" has an unconfirmed earlier submission; skipped to avoid duplicates")
                continue
            }
            await continueOne(paused: paused, auto: false)
        }
    }

    /// 在 Codex 桌面 app 中打开指定对话（官方深链 codex://threads/<id>）
    func openInCodex(threadId: String) {
        guard let url = URL(string: "codex://threads/\(threadId)") else { return }
        NSWorkspace.shared.open(url)
        appendLog("已在 Codex 中打开对话 \(threadId)", "Opened chat \(threadId) in Codex")
    }

    // MARK: - 辅助功能授权监控（授权后自动重启生效）

    private var accessibilityMonitorTimer: Timer?

    /// 辅助功能未授权时的通知（不自动弹系统设置，避免反复打扰）
    func notifyNeedAccessibility() {
        accessibilityAuthorized = AppleScriptAutomation.hasAccessibilityPermission()
        let note = NSUserNotification()
        note.title = "CodexReset"
        note.informativeText = "辅助功能未授权，无法在 Codex 中输入「继续」。请点面板「授权辅助功能」勾选本 App（若勾选过仍提示，请重新勾选一次）。"
        NSUserNotificationCenter.default.deliver(note)
    }

    /// 手动打开系统设置引导授权，并轮询检测；一旦授权完成自动重启本 App
    func openAccessibilitySettings() {
        guard !AppleScriptAutomation.hasAccessibilityPermission() else {
            appendLog("辅助功能已授权", "Accessibility granted")
            return
        }
        AppleScriptAutomation.openAccessibilitySettings()
        appendLog("请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选本 App，授权后会自动重启生效",
                  "Please check this app in System Settings → Privacy & Security → Accessibility; it will restart automatically once granted")
        accessibilityMonitorTimer?.invalidate()
        accessibilityMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AppleScriptAutomation.hasAccessibilityPermission() {
                    self.accessibilityMonitorTimer?.invalidate()
                    self.accessibilityMonitorTimer = nil
                    self.restartAfterAuthorization()
                }
            }
        }
    }

    /// 授权完成：清理子进程并用 launchctl 重启（由 LaunchAgent 管理）
    private func restartAfterAuthorization() {
        appendLog("检测到辅助功能已授权，自动重启生效…", "Accessibility granted detected; restarting to apply…")
        manager.stopOwnServer()
        let uid = getuid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "-k", "gui/\(uid)/com.codexreset.CodexReset"]
        do {
            try proc.run()
        } catch {
            appendLog("自动重启失败，请手动重启：\(error)", "Auto-restart failed; please restart manually: \(error)")
            return
        }
        exit(0)
    }

    // MARK: - 工具

    private func appendLog(_ zh: String, _ en: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let stamp = formatter.string(from: Date())
        logLines.append(LogEntry(time: stamp, zh: zh, en: en))
        if logLines.count > 100 { logLines.removeFirst(logLines.count - 100) }
    }

    private func notify(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try? AppleScriptAutomation.runAppleScript(
            #"display notification "\#(escapedBody)" with title "\#(escapedTitle)""#
        )
    }

    /// 格式化恢复倒计时
    func countdownText() -> String? {
        guard let primary = rateLimits?.rateLimits.primary,
              let resetsAt = primary.resetsAt else { return nil }
        let now = Date().timeIntervalSince1970
        let remain = Double(resetsAt) - now
        if remain <= 0 { return L("已恢复", "recovered") }
        let totalMinutes = Int(remain) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return L("\(hours)小时\(minutes)分", "\(hours)h \(minutes)m") }
        return L("\(minutes)分钟", "\(minutes)m")
    }
}
