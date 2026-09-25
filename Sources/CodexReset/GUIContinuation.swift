import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// GUI Tier 1 发送事务的三态结果
enum GUIContinuationResult {
    /// 目标 thread 持久化了本次 prompt，且属于新 turn，turn 状态 inProgress/completed
    case confirmedSuccess(turnId: String)
    /// 明确失败。delivered=false：Desktop 未收到任何 prompt，调用方允许 fallback Tier 2；
    /// delivered=true：Desktop 已收到 prompt（turn failed/interrupted，或投递到错误 thread），调用方禁止再发
    case confirmedFailure(reason: String, delivered: Bool)
    /// 无法确认：不宣布成功、不标已处理、禁止 fallback Tier 2；baseline 带出供后续轮询 reconciliation
    case uncertain(reason: String, baseline: SubmissionBaseline)
}

/// Codex Desktop GUI 发送事务：深链/激活 → AX 聚焦 composer → 剪贴板粘贴 → Cmd+Enter → SQLite 回执确认
final class GUIContinuationController {
    /// Codex Desktop（ChatGPT.app）的 bundle id
    private static let codexBundleId = "com.openai.codex"

    private let codexHome: String

    var onLog: ((String, String) -> Void)?

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    // MARK: - 主入口

    /// 完整发送事务（故意阻塞；含重试与回执轮询，总时长不超过约 35s）。只允许由 AutoContinueEngine 调用。
    func sendContinuation(threadId: String, command: String) -> GUIContinuationResult {
        // ── A. Preflight ──
        if !AppleScriptAutomation.hasAccessibilityPermission() {
            log("GUI Tier 1：辅助功能未授权，无法发送", "GUI Tier 1: accessibility permission missing, abort")
            return .confirmedFailure(reason: "辅助功能未授权", delivered: false)
        }
        if !hasPostEventPermission() {
            log("GUI Tier 1：未授权「发送事件」权限（PostEvent），无法注入键盘事件",
                "GUI Tier 1: post-event permission missing, cannot inject keystrokes")
            return .confirmedFailure(reason: "未授权发送事件权限（PostEvent），无法注入键盘事件", delivered: false)
        }
        let reader = SQLiteReader(codexHome: codexHome)
        guard let baseline = reader.captureSubmissionBaseline(threadId: threadId) else {
            log("GUI Tier 1：thread_history 不可读，无法建立回执基线，放弃盲发",
                "GUI Tier 1: thread_history unreadable, cannot build receipt baseline; refusing blind send")
            return .confirmedFailure(reason: "thread_history 不可读，无法建立回执基线", delivered: false)
        }
        log("GUI Tier 1：回执基线已建立（maxOrdinal=\(baseline.maxOrdinal)，既有 turn \(baseline.turnIds.count) 个）",
            "GUI Tier 1: receipt baseline captured (maxOrdinal=\(baseline.maxOrdinal), \(baseline.turnIds.count) existing turns)")

        // ── B. Navigate ──
        let app: NSRunningApplication
        switch navigateToThread(threadId) {
        case .activated(let running):
            app = running
        case .appNotFound:
            log("GUI Tier 1：找不到 Codex Desktop app", "GUI Tier 1: Codex Desktop app not found")
            return .confirmedFailure(reason: "找不到 Codex Desktop app", delivered: false)
        case .coldStartTimeout:
            log("GUI Tier 1：Codex Desktop 冷启动超时", "GUI Tier 1: Codex Desktop cold start timed out")
            return .confirmedFailure(reason: "Codex Desktop 冷启动超时", delivered: false)
        case .activateFailed:
            log("GUI Tier 1：Codex Desktop 无法激活", "GUI Tier 1: failed to activate Codex Desktop")
            return .confirmedFailure(reason: "Codex Desktop 无法激活", delivered: false)
        }

        // ── C. Focus composer ──
        // Electron 的 AX 树在 AX 客户端附着后异步物化：激活后稍等再扫，避免第 1 轮永远空跑
        Thread.sleep(forTimeInterval: 0.8)
        let pid = app.processIdentifier
        guard focusComposer(pid: pid) else {
            log("GUI Tier 1：无法定位或聚焦输入框", "GUI Tier 1: cannot locate or focus the composer")
            return .confirmedFailure(reason: "无法定位或聚焦输入框", delivered: false)
        }
        let appElement = AXUIElementCreateApplication(pid)

        // ── D. Paste + Submit ──
        let firstSubmitAt: Date
        switch pasteAndSubmit(command: command, app: app, appElement: appElement) {
        case .failed(let result):
            return result
        case .submitted(let at):
            firstSubmitAt = at
        }

        // ── E. Reconcile（SQLite 回执，唯一成功标准）──
        return reconcile(threadId: threadId, command: command, baseline: baseline,
                         reader: reader, appElement: appElement, firstSubmitAt: firstSubmitAt)
    }

    // MARK: - A. Preflight

    /// PostEvent 权限：macOS 15+ 需显式 preflight（deployment target 14，必须 #available 包裹），14 上直接放行
    private func hasPostEventPermission() -> Bool {
        if #available(macOS 15.0, *) {
            return CGPreflightPostEventAccess()
        }
        return true
    }

    // MARK: - B. Navigate

    private enum NavigateResult {
        case activated(NSRunningApplication)
        case appNotFound       // 系统里没有 Codex Desktop
        case coldStartTimeout  // 冷启动 15s 未完成
        case activateFailed    // 3 轮重试后窗口仍未激活
    }

    /// 深链打开对话 → 校验 Desktop ready（必要时冷启动）→ 激活前台。整体最多 3 轮，轮间隔 0.5s/1s。
    private func navigateToThread(_ threadId: String) -> NavigateResult {
        let deepLink = URL(string: "codex://threads/\(threadId)")
        let intervals: [TimeInterval] = [0.5, 1.0]
        for round in 0..<3 {
            if round > 0 {
                log("GUI Tier 1：导航第 \(round + 1) 轮…", "GUI Tier 1: navigate round \(round + 1)…")
            }
            // open 返回成功只代表 LaunchServices 接受请求，不代表 Desktop ready
            if let deepLink {
                NSWorkspace.shared.open(deepLink)
            }
            // 轮询进程存在且 isFinishedLaunching（每 0.25s，最多 10s）
            if !waitForLaunch(timeout: 10) {
                // 超时：可能未安装或冷启动失败，定位 app 后尝试显式启动
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleId) else {
                    return .appNotFound
                }
                guard coldStart(appURL: appURL) else {
                    return .coldStartTimeout
                }
                // 启动成功后重新发送同一个 deep link，等界面加载
                if let deepLink {
                    NSWorkspace.shared.open(deepLink)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            // 激活并轮询 isActive（每 0.25s，最多 3s）
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.codexBundleId).first else {
                if round < 2 { Thread.sleep(forTimeInterval: intervals[round]) }
                continue
            }
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            if waitForActive(app, timeout: 3) {
                log("GUI Tier 1：Codex Desktop 已激活", "GUI Tier 1: Codex Desktop activated")
                return .activated(app)
            }
            if round < 2 { Thread.sleep(forTimeInterval: intervals[round]) }
        }
        return .activateFailed
    }

    /// 轮询 Codex Desktop 进程存在且 isFinishedLaunching
    private func waitForLaunch(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.codexBundleId).first,
               app.isFinishedLaunching {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// 显式冷启动 Codex Desktop，再等 isFinishedLaunching（最多 15s）
    private func coldStart(appURL: URL) -> Bool {
        log("GUI Tier 1：deep link 未唤起 Desktop，尝试冷启动…",
            "GUI Tier 1: deep link did not wake Desktop; cold-starting…")
        var launchError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            launchError = error
            semaphore.signal()
        }
        // openApplication 的 completion 很快；信号量超时只是兜底，真正就绪以下面轮询为准
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            log("GUI Tier 1：openApplication 回调超时", "GUI Tier 1: openApplication completion timed out")
        }
        if let launchError {
            log("GUI Tier 1：冷启动失败：\(launchError)", "GUI Tier 1: cold start failed: \(launchError)")
            return false
        }
        let ok = waitForLaunch(timeout: 15)
        log(ok ? "GUI Tier 1：冷启动完成" : "GUI Tier 1：冷启动后 15s 仍未就绪",
            ok ? "GUI Tier 1: cold start finished" : "GUI Tier 1: still not ready 15s after cold start")
        return ok
    }

    /// 轮询 isActive
    private func waitForActive(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.isActive { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // MARK: - C. Focus composer

    /// composer 候选：可编辑文本控件 + 几何信息（打分用）
    private struct ComposerCandidate {
        let element: AXUIElement
        let frame: CGRect
        let isTextArea: Bool
        let isEditable: Bool
    }

    /// 定位前台窗口 → AX 树收集候选输入框 → 聚焦并验证；失败时每轮回退鼠标点击一次。
    /// 3 轮均失败返回 false（绝不允许带着未验证的焦点进入输入阶段）。
    private func focusComposer(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        let intervals: [TimeInterval] = [0.5, 1.0]
        for round in 0..<3 {
            guard let window = focusedWindow(of: appElement),
                  let frame = windowFrame(window) else {
                log("GUI Tier 1：第 \(round + 1) 轮未取到前台窗口", "GUI Tier 1: round \(round + 1): no front window")
                if round < 2 { Thread.sleep(forTimeInterval: intervals[round]) }
                continue
            }
            // 递归遍历 AX 树收集候选（节点上限 8000；侧边栏可达数百节点，上限过小 DFS 走不到主区）
            var visited = 0
            var candidates: [ComposerCandidate] = []
            collectComposerCandidates(in: window, windowFrame: frame, visited: &visited, into: &candidates)
            if let best = candidates.max(by: composerLess),
               focusComposerCandidate(best.element, appElement: appElement) {
                log("GUI Tier 1：已通过 AX 聚焦输入框（第 \(round + 1) 轮，候选 \(candidates.count) 个）",
                    "GUI Tier 1: composer focused via AX (round \(round + 1), \(candidates.count) candidates)")
                return true
            }
            // 最后回退（每轮一次）：鼠标点击窗口底部，等 Electron AX 树物化后重扫聚焦
            if clickComposerFallback(appElement: appElement, windowFrame: frame, window: window) {
                log("GUI Tier 1：已通过点击窗口底部聚焦输入框（第 \(round + 1) 轮）",
                    "GUI Tier 1: composer focused via bottom click (round \(round + 1))")
                return true
            }
            log("GUI Tier 1：第 \(round + 1) 轮聚焦输入框失败", "GUI Tier 1: round \(round + 1): focus composer failed")
            if round < 2 { Thread.sleep(forTimeInterval: intervals[round]) }
        }
        return false
    }

    /// 打分排序：AXTextArea 优先，其次 AXEditable，再次面积更大者
    private func composerLess(_ lhs: ComposerCandidate, _ rhs: ComposerCandidate) -> Bool {
        if lhs.isTextArea != rhs.isTextArea { return !lhs.isTextArea }
        if lhs.isEditable != rhs.isEditable { return !lhs.isEditable }
        return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
    }

    /// 取前台窗口：优先 focused window，回退 windows 列表第一个
    private func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
            return unsafeDowncast(winRef, to: AXUIElement.self)
        }
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let wins = winsRef as? [AXUIElement], let first = wins.first {
            return first
        }
        return nil
    }

    /// 递归收集 composer 候选：role 为文本控件、enabled、非搜索框、位于窗口下半部、宽度 ≥ 窗口 40%。
    /// 节点上限取 8000：DFS 会先扫完整侧边栏（200+ 对话可达数百节点），上限太小走不到主区（2026-09-25 实证 bug）。
    private func collectComposerCandidates(in element: AXUIElement, windowFrame: CGRect,
                                           visited: inout Int, into candidates: inout [ComposerCandidate]) {
        guard visited < 8000 else { return }
        visited += 1

        // 收集条件：文本控件；enabled 不为 false；非搜索框；位于窗口下半部；宽度 ≥ 窗口 40%。
        // 禁用 placeholder/标题文本判断，只用几何与状态约束
        if let role = axString(element, kAXRoleAttribute as CFString),
           role == kAXTextAreaRole || role == kAXTextFieldRole,
           axBool(element, kAXEnabledAttribute as CFString) ?? true,
           axString(element, kAXSubroleAttribute as CFString) != "AXSearchField",
           let origin = axPoint(element, kAXPositionAttribute as CFString),
           let size = axSize(element, kAXSizeAttribute as CFString) {
            let frame = CGRect(origin: origin, size: size)
            if frame.midY > windowFrame.midY, frame.width >= windowFrame.width * 0.4 {
                candidates.append(ComposerCandidate(
                    element: element, frame: frame,
                    isTextArea: role == kAXTextAreaRole,
                    isEditable: axBool(element, "AXEditable" as CFString) ?? false))
            }
        }

        guard let children = axChildren(element) else { return }
        for child in children {
            collectComposerCandidates(in: child, windowFrame: windowFrame, visited: &visited, into: &candidates)
        }
    }

    /// 聚焦候选，并验证 application 的 focusedUIElement 与候选 CFEqual 才算成功
    private func focusComposerCandidate(_ candidate: AXUIElement, appElement: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            return false
        }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        return CFEqual(unsafeDowncast(focusedRef, to: AXUIElement.self), candidate)
    }

    /// 最后回退：CGEvent 点击窗口底部（midX, maxY-60；输入框实测位于窗口底部上方 55~110pt 区间）。
    /// Electron 的 AX 树在真实点击聚焦后才物化（2026-09-25 axdump 实证）：点击后稍等并
    /// 重新扫描候选，命中 AXTextArea 就走标准 AX 聚焦验证；否则退回「focused element role 检查」。
    private func clickComposerFallback(appElement: AXUIElement, windowFrame: CGRect, window: AXUIElement) -> Bool {
        let point = CGPoint(x: windowFrame.midX, y: windowFrame.maxY - 60)
        postMouseClick(at: point)
        Thread.sleep(forTimeInterval: 0.6)
        // 树物化后重扫候选，走标准 AX 聚焦 + CFEqual 验证
        var visited = 0
        var candidates: [ComposerCandidate] = []
        collectComposerCandidates(in: window, windowFrame: windowFrame, visited: &visited, into: &candidates)
        if let best = candidates.max(by: composerLess),
           focusComposerCandidate(best.element, appElement: appElement) {
            return true
        }
        // 退化判定：focused element 是可编辑文本控件即算成功
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        let focused = unsafeDowncast(focusedRef, to: AXUIElement.self)
        guard let role = axString(focused, kAXRoleAttribute as CFString),
              role == kAXTextAreaRole || role == kAXTextFieldRole else {
            return false
        }
        // enabled 为 false 视为验证不过
        if let enabled = axBool(focused, kAXEnabledAttribute as CFString), !enabled {
            return false
        }
        return true
    }

    // MARK: - D. Paste + Submit

    /// D. Paste + Submit 的结果：已提交（带首次提交时刻）或本阶段明确失败
    private enum PasteSubmitOutcome {
        case submitted(firstSubmitAt: Date)
        case failed(GUIContinuationResult)
    }

    /// 粘贴 + 提交。
    /// 口径（用户 2026-09-25 裁定）：
    /// 1) 不检查输入框是否有残留内容——有就直接追加到末尾发送，绝不因残留放弃发送；
    ///    回执匹配用「相等或以 command 结尾」兼容追加语义。
    /// 2) 粘贴可重试（最多 3 轮，退避 0.5s/1s）：聚焦后用户可能切走窗口导致 Cmd+V 落到别的 app
    ///    （2026-09-25 实测失败案例），每轮先校验 Codex 仍在前台（不在则重新激活并重新聚焦），
    ///    校验通过才发键盘事件。重试只发生在提交前，无业务副作用。
    private func pasteAndSubmit(command: String, app: NSRunningApplication, appElement: AXUIElement) -> PasteSubmitOutcome {
        let pasteboard = NSPasteboard.general
        // 快照原剪贴板所有类型，defer 恢复（禁止永久覆盖用户剪贴板）
        var saved: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) {
                saved.append((type, data))
            }
        }
        defer {
            pasteboard.clearContents()
            for item in saved {
                pasteboard.setData(item.data, forType: item.type)
            }
        }

        let backoff: [TimeInterval] = [0.5, 1.0]
        for round in 0..<3 {
            // 1) 前台校验：焦点可能被用户切走；不在前台先激活（激活后焦点未必回输入框，重走聚焦）
            if !app.isActive {
                log("GUI Tier 1：第 \(round + 1) 轮粘贴前 Codex 不在前台，重新激活…",
                    "GUI Tier 1: round \(round + 1): Codex not frontmost before paste; reactivating…")
                app.activate(options: [.activateAllWindows])
                var becameActive = false
                for _ in 0..<8 { // 最多 2s
                    Thread.sleep(forTimeInterval: 0.25)
                    if app.isActive { becameActive = true; break }
                }
                if !becameActive {
                    log("GUI Tier 1：第 \(round + 1) 轮重新激活失败", "GUI Tier 1: round \(round + 1): reactivation failed")
                    if round < 2 { Thread.sleep(forTimeInterval: backoff[round]) }
                    continue
                }
                guard focusComposer(pid: app.processIdentifier) else {
                    log("GUI Tier 1：第 \(round + 1) 轮重新聚焦输入框失败", "GUI Tier 1: round \(round + 1): refocus composer failed")
                    if round < 2 { Thread.sleep(forTimeInterval: backoff[round]) }
                    continue
                }
            }

            // 2) 写剪贴板 → 光标移到文档末尾（Cmd+↓，追加语义）→ Cmd+V，等粘贴落地
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            postKeyCombo(keyCode: 125) // 125 = Down Arrow
            postKeyCombo(keyCode: 9)   // 9 = V
            Thread.sleep(forTimeInterval: 0.5)

            // 3) 粘贴校验：含 command = 本轮成功；读不到/非 String = 不可读，继续走，交给 DB 回执兜底
            if let text = focusedComposerText(appElement: appElement) {
                guard text.contains(command) else {
                    log("GUI Tier 1：第 \(round + 1) 轮粘贴未生效（输入框不含 prompt 文本）",
                        "GUI Tier 1: round \(round + 1): paste had no effect (composer lacks the prompt text)")
                    if round < 2 { Thread.sleep(forTimeInterval: backoff[round]) }
                    continue
                }
            }
            return submitStage(command: command, appElement: appElement)
        }
        log("GUI Tier 1：粘贴重试 3 轮均未生效", "GUI Tier 1: paste ineffective across 3 rounds")
        return .failed(.confirmedFailure(reason: "粘贴未生效（重试 3 轮）", delivered: false))
    }

    /// Cmd+Enter 提交，记录首次提交时刻；1s 后复读：composer 仍保留完整 command = 提交未生效，只允许再按一次
    private func submitStage(command: String, appElement: AXUIElement) -> PasteSubmitOutcome {
        postKeyCombo(keyCode: 36) // 36 = Return
        let firstSubmitAt = Date()
        log("GUI Tier 1：已发送 Cmd+Enter，等待 SQLite 回执…",
            "GUI Tier 1: Cmd+Enter sent; awaiting SQLite evidence…")

        Thread.sleep(forTimeInterval: 1.0)
        if let text = focusedComposerText(appElement: appElement), text.contains(command) {
            log("GUI Tier 1：提交未生效（输入框仍保留原文），重按一次 Cmd+Enter",
                "GUI Tier 1: submit had no effect (composer still holds the text); pressing Cmd+Enter once more")
            postKeyCombo(keyCode: 36)
            Thread.sleep(forTimeInterval: 1.0)
        }
        return .submitted(firstSubmitAt: firstSubmitAt)
    }

    /// 发 Cmd+组合键（down/up 各一次，CGHIDEventTap）
    private func postKeyCombo(keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postMouseClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - E. Reconcile（SQLite 回执，唯一成功标准）

    /// 首次提交后按 0.5/1/2/4/8s 共 5 轮查回执；均无证据再做 misroute 排查与 composer 复读。
    private func reconcile(threadId: String, command: String, baseline: SubmissionBaseline,
                           reader: SQLiteReader, appElement: AXUIElement,
                           firstSubmitAt: Date) -> GUIContinuationResult {
        let waits: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0]
        var lastEvidence: SubmissionEvidence?
        for wait in waits {
            Thread.sleep(forTimeInterval: wait)
            guard let evidence = reader.findSubmissionEvidence(threadId: threadId, baseline: baseline, command: command) else {
                continue
            }
            lastEvidence = evidence
            if !evidence.isNewTurn {
                // 文本落进了发送前已存在的 turn：不宣布成功，继续观察
                log("GUI Tier 1：userMessage 落入已存在 turn \(evidence.turnId)，继续轮询",
                    "GUI Tier 1: userMessage landed in a pre-existing turn \(evidence.turnId); keep polling")
                continue
            }
            switch evidence.turnStatus {
            case "inProgress", "completed":
                log("GUI Tier 1：SQLite 回执确认新 turn \(evidence.turnId)（\(evidence.turnStatus)）",
                    "GUI Tier 1: SQLite evidence confirms new turn \(evidence.turnId) (\(evidence.turnStatus))")
                return .confirmedSuccess(turnId: evidence.turnId)
            case "failed", "interrupted":
                // Desktop 已收到 prompt 但 turn 失败：禁止再发
                let message = turnErrorMessage(evidence.turnErrorJson)
                log("GUI Tier 1：Desktop 已接收 prompt 但 turn \(evidence.turnStatus)：\(message)",
                    "GUI Tier 1: Desktop received the prompt but the turn \(evidence.turnStatus): \(message)")
                return .confirmedFailure(reason: "Desktop 已接收 prompt 但 turn \(evidence.turnStatus)：\(message)",
                                         delivered: true)
            default:
                // queued/pending/空：继续轮询
                continue
            }
        }

        // 最后一轮证据仍是「落入已存在 turn」：无法确认，不标已处理、禁止 fallback
        if let evidence = lastEvidence, !evidence.isNewTurn {
            log("GUI Tier 1：轮询结束，userMessage 仍落在已存在 turn，结果未知",
                "GUI Tier 1: polling done; userMessage still in a pre-existing turn, outcome unknown")
            return .uncertain(reason: "userMessage 落入已存在 turn", baseline: baseline)
        }

        // misroute 排查：相同文本进了别的 thread = 明确已投递，禁止再发
        if let hit = reader.findPossibleMisroute(afterMs: baseline.attemptStartedAtMs,
                                                 command: command, excludingThreadId: threadId) {
            log("GUI Tier 1：相同 prompt 进入了错误对话 \(hit.threadId)（turn \(hit.turnId)）",
                "GUI Tier 1: identical prompt landed in the wrong thread \(hit.threadId) (turn \(hit.turnId))")
            return .confirmedFailure(reason: "投递到了错误对话 \(hit.threadId)", delivered: true)
        }

        // 最终 composer 复读：仍保留完整原文 = 强「未提交」证据，允许 Tier 2 接管
        if let text = focusedComposerText(appElement: appElement), text.contains(command) {
            log("GUI Tier 1：提交未生效（输入框仍保留原文），允许 Tier 2 接管",
                "GUI Tier 1: submit never took effect (composer still holds the text); Tier 2 may take over")
            return .confirmedFailure(reason: "提交未生效（输入框仍保留原文）", delivered: false)
        }
        log("GUI Tier 1：输入框已清空但数据库尚无记录（距首次提交 \(Int(Date().timeIntervalSince(firstSubmitAt)))s），结果未知",
            "GUI Tier 1: composer cleared but no DB record yet (\(Int(Date().timeIntervalSince(firstSubmitAt)))s since submit); outcome unknown")
        return .uncertain(reason: "输入框已清空但数据库尚无记录", baseline: baseline)
    }

    /// 从 turn 的 error_json 解析 message；解析失败用原文截断
    private func turnErrorMessage(_ errorJson: String?) -> String {
        guard let errorJson, !errorJson.isEmpty else { return "无错误详情" }
        if let data = errorJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        return String(errorJson.prefix(200))
    }

    // MARK: - AX 读取辅助

    private func log(_ zh: String, _ en: String) {
        onLog?(zh, en)
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        guard let origin = axPoint(window, kAXPositionAttribute as CFString),
              let size = axSize(window, kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// 读当前 focused element 的文本；读不到/非 String 返回 nil（调用方按「不可读」处理）
    private func focusedComposerText(appElement: AXUIElement) -> String? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return axString(unsafeDowncast(focusedRef, to: AXUIElement.self), kAXValueAttribute as CFString)
    }

    private func axString(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private func axBool(_ element: AXUIElement, _ attr: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? Bool
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    private func axPoint(_ element: AXUIElement, _ attr: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(ref, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attr: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(ref, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }
}

/// 少量仍需的 AppleScript 辅助（通知用）
struct AppleScriptAutomation {
    /// 检测辅助功能权限
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统官方授权弹窗（kAXTrustedCheckOptionPrompt），返回当前是否已授权。
    /// 弹窗由系统绘制、自带「打开系统设置」按钮，App 会自动进入辅助功能列表；重复调用不会反复弹窗。
    @discardableResult
    static func promptAccessibilityIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
