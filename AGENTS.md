# CodexReset 项目协作规则

本文件只记录通用规则与边界；动态进度与 handoff 见 `CLAUDE.md`。

## 项目概况

CodexReset 是 Codex 桌面 app 的 macOS 菜单栏伴侣：监控 5h/1w 用量窗口，额度恢复后自动向用户勾选的对话发送全局 continuation prompt（默认「继续」）。

- 上游仓库：`boyso/codex-reset`（本工作区是其本地改造副本，upstream base commit：`10def8531262a15d5f00c73ce4264baf0e18290c`）
- 技术栈：纯 Swift（SwiftPM，swift-tools 5.9），AppKit + SwiftUI，系统 SQLite3，无第三方依赖（**禁止新增依赖**）
- 运行环境：macOS 14+，本机 Codex runtime 来自 `/Applications/ChatGPT.app/Contents/Resources/codex`

## 构建与运行

```bash
swift build -c release          # 编译
./make_app.sh                   # 打包并安装 /Applications/CodexReset.app（ad-hoc/开发证书签名）
.build/release/CodexReset --query              # 无头：打印用量与暂停线程
.build/release/CodexReset --continue <thread_id>  # 无头：继续指定线程（跳过 GUI 直走 Tier 2；会真实发送 prompt，慎用）
```

## 硬性安全边界（必须遵守）

1. **禁止 broad 进程清理**：不得 `pkill -f` / 扫描杀死任何 Codex/app-server 进程；只能终止本 App 自己 `Process` 持有的子进程。
2. **禁止修改 Codex 侧状态**：不改 `~/.codex/config.toml` / `~/.codex/auth*` / Codex Desktop App；不安装 standalone CLI；不重启/不 kill Codex Desktop；不 bootstrap 任何 daemon（旧 Remote Control 路线已整体废弃删除）。
3. **发送限制**：禁止向重要生产 thread 发送测试 prompt。真实端到端发送只允许用一次性临时测试 thread，且须先获用户明确授权。
4. **不扩大产品面**：未经用户明确要求，不改主面板布局、对话列表、双击打开会话、全局 prompt 控件、用量监控 UI；不做 Goal、per-thread prompt、selectedThreadIds 持久化、SQLite schema 变更。
5. 文件删除遵循用户全局规则（仓库内移到 `.archive/`，已 gitignore）。
6. 未收到明确要求前不 git commit / push（2026-09-25 用户已授权本轮起自主提交）。

## 通道架构（两层 fallback，2026-09-25 转向后）

```
Tier 1  Codex Desktop GUI 自动化（codex://threads/<id> 深链 → AX 聚焦 composer → 剪贴板粘贴提交）
   ↓ 仅当明确「未提交任何 prompt」
Tier 2  bundled codex app-server（stdio JSON-RPC，lazy 启动，独占持有进程）
```

- Tier 1 的「成功」**不以按键/AppleScript 事件成功为准**，只以 `~/.codex/thread_history_1.sqlite` 回执为准：目标 thread 出现 `rollout_ordinal > baseline`、文本与 prompt 一致的新 `userMessage`，且其新 `turnId` 状态为 `inProgress`/`completed` → `confirmedSuccess`。
- 三态：**confirmedSuccess / confirmedFailure / uncertain**。`failed`/`interrupted` 或 misroute = 已投递（禁止 Tier 2 重发、不标已处理）；`uncertain` = 保持 pending 由后续轮询 DB 补查，**绝不盲目重试、绝不立即 Tier 2**。
- **硬约束**：GUI Tier 1 对某 thread 的尝试在确认完成前，Tier 2 不得对同一 thread 做任何写操作（引擎顺序执行保证）。
- Tier 2 仅在 GUI 明确未提交（权限缺失、app 无法激活、composer 定位失败、粘贴未生效、提交未发生）时启用。
- `handledThreads` 只在明确成功或 reconciliation 确认后加入。
- 额度恢复许可唯一依据：`ordinaryUsageAllowed == true && rateLimitReachedType ∈ {nil,"none"} && spendControlReached != true`；`usedPercent` 仅用于 UI，primary `resetsAt` 同时用于识别 5h rollover，但二者都不授予发送许可。

## 文档分工

- `README.md`：fork 的稳定项目事实、运行与测试入口、重要文档索引
- `AGENTS.md`：本文件，规则与边界
- `CLAUDE.md`：当前改造进度、已验证协议事实、handoff（**每次会话结束/中断前必须更新**）
