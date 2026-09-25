import AppKit
import SwiftUI
import Combine

/// 菜单栏控制器：用量进度环 + 百分比文本 + 弹出面板
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var titleTimer: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        setup()
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.imagePosition = .imageLeading
            button.title = "Codex…"
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = L("Codex 用量监控", "Codex usage monitor")
        }

        let rootView = ContentView().environmentObject(model)
        let hosting = NSHostingController(rootView: rootView)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 760)
        popover.behavior = .transient
        popover.contentViewController = hosting

        // 数据变化时刷新标题
        model.$rateLimits
            .combineLatest(model.$connectionMode)
            .sink { [weak self] _, _ in
                Task { @MainActor in self?.updateTitle() }
            }
            .store(in: &cancellables)

        // 每秒刷新倒计时
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        // 用量窗口（5小时）决定状态栏饼图与百分比
        guard model.connectionMode != "connecting",
              model.connectionMode != "none",
              let primary = model.rateLimits?.rateLimits.primary else {
            button.image = nil
            switch model.connectionMode {
            case "none":
                button.title = "Codex ⚠️"
            default:
                button.title = "Codex…"
            }
            return
        }

        let used = primary.usedPercent
        if used >= 100 {
            // 已到上限：红色满环 + 恢复倒计时
            button.image = usageRingImage(percent: used)
            if let countdown = model.countdownText() {
                button.title = "⏳ \(countdown)"
            } else {
                button.title = "⏳ " + L("已到上限", "limit reached")
            }
        } else {
            // 正常：用量进度环 + 百分比
            button.image = usageRingImage(percent: used)
            button.title = "\(used)%"
        }
    }

    /// 绘制用量进度环（深/浅菜单栏均清晰）：灰底环 + 彩色用量弧
    private func usageRingImage(percent: Int) -> NSImage {
        let pct = min(max(percent, 0), 100)
        // 2 倍尺寸绘制，缩小后更锐利
        let backing = NSImage(size: NSSize(width: 36, height: 36))
        backing.lockFocus()
        let rect = NSRect(x: 4, y: 4, width: 28, height: 28)
        let lineWidth: CGFloat = 4.5

        // 底环（自适应明暗外观）
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()

        if pct > 0 {
            let arcColor: NSColor = pct >= 100
                ? .systemRed
                : (pct >= 80 ? .systemOrange : .systemGreen)
            let frac = CGFloat(pct) / 100.0
            let arc = NSBezierPath()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.appendArc(
                withCenter: NSPoint(x: rect.midX, y: rect.midY),
                radius: rect.width / 2,
                startAngle: 90,          // 12 点方向开始
                endAngle: 90 - 360 * frac, // 顺时针扫过 used%
                clockwise: true
            )
            arcColor.setStroke()
            arc.stroke()
        }
        backing.unlockFocus()
        backing.size = NSSize(width: 18, height: 18)
        return backing
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
