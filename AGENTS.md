# CodexReset 项目协作规则

本文件只记录通用规则与边界；动态进度与 handoff 见 `CLAUDE.md`。

## 项目概况

CodexReset 是 Codex 桌面 app 的 macOS 菜单栏伴侣：监控 5h/1w 用量窗口，额度恢复后自动向用户勾选的对话发送全局 continuation prompt（默认「继续」）。

- 上游仓库：`boyso/codex-reset`（本工作区是其本地改造副本，upstream base commit：`10def8531262a15d5f00c73ce4264baf0e18290c`）
- 技术栈：纯 Swift（SwiftPM，swift-tools 5.9），AppKit + SwiftUI，无第三方依赖（**禁止新增依赖**）
- 运行环境：macOS 14+，本机 Codex runtime 来自 `/Applications/ChatGPT.app/Contents/Resources/codex`

## 构建与运行

```bash
swift build -c release          # 编译
./make_app.sh                   # 打包并安装 /Applications/CodexReset.app（ad-hoc/开发证书签名）
.build/release/CodexReset --query              # 无头：打印用量与暂停线程
.build/release/CodexReset --continue <thread_id>  # 无头：继续指定线程（会真实发送 prompt，慎用）
```

## 硬性安全边界（必须遵守）

1. **禁止 broad 进程清理**：不得 `pkill -f` / 扫描杀死任何 Codex/app-server 进程；只能终止本 App 自己 `Process` 持有的子进程。
2. **禁止修改 Codex 侧状态**：不改 `~/.codex/config.toml`（用户手动 toggle 写配置除外）、`~/.codex/auth*`、Codex Desktop App；不安装 standalone CLI；不重启/不 kill Codex Desktop。
3. **验收不得真实发送 prompt**：协议验证只做只读调用（initialize、rateLimits/read、thread/resume excludeTurns、turns/list）；`turn/start` 只允许对「不存在的 thread id」探测参数校验。
4. **Remote Control daemon 由用户自己维护**：本 App 只探测 `$CODEX_HOME/app-server-control/app-server-control.sock` 是否健康，不 bootstrap、不重启、不更新。
5. **不扩大产品面**：不改 ContentView/SettingsPanelView 布局、对话列表、双击打开会话、全局 prompt 控件、GUI Accessibility fallback 实现；不做 Goal、per-thread prompt、selectedThreadIds 持久化、SQLite schema 变更。
6. 文件删除遵循用户全局规则（仓库内移到 `.archive/`）。
7. 未收到明确要求前不 git commit / push。

## 通道架构（三层 fallback，无用户开关）

```
Tier 1  Remote Control control socket（完整健康探测通过才算可用）
   ↓ 明确失败
Tier 2  bundled codex app-server（stdio JSON-RPC，lazy 启动，独占持有进程）
   ↓ 明确失败
Tier 3  GUI / Accessibility fallback（深链 + 粘贴 + ⌘Enter）
```

- 每层 continuation 结果分三态：**明确成功 / 明确失败 / 结果未知（ambiguous）**。
- ambiguous（turn/start 写出后超时/断连）**禁止直接重发**：先 `thread/turns/list` 按 `clientUserMessageId` 对账；确认未进入 thread 才允许下一层；无法对账则保持 uncertain，等下轮补查。
- `handledThreads` 只在明确成功或对账确认后加入。
- 额度恢复许可唯一依据：`ordinaryUsageAllowed == true && rateLimitReachedType ∈ {nil,"none"} && spendControlReached != true`；`usedPercent`/`resetsAt` 仅用于 UI。

## 文档分工

- `README.md`：上游稳定事实与入口（暂保持上游原文，交付后再评估是否补充 fork 说明）
- `AGENTS.md`：本文件，规则与边界
- `CLAUDE.md`：当前改造进度、已验证协议事实、handoff（**每次会话结束/中断前必须更新**）
