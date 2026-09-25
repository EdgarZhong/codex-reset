# CodexReset 控制链路转向（GUI Tier 1 + DB 回执）— 进度同步与 Handoff

> 动态文档，随推进更新。规则与边界见 `AGENTS.md`。最后更新：2026-09-25 会话三（本轮改造完成并安装，待 19:11 confirmed 路径实证）

## 1. 当前目标（唯一核心）

当 Codex 订阅额度恢复时，可靠地向用户勾选的既有 Codex thread 发送当前全局 continuation prompt。**优先进入正在运行的 Codex Desktop（ChatGPT.app）原 thread 并在 GUI 可见地继续**（一个 session 只能被一个内核接管，另起 app-server 用户看不到进展）；GUI 明确未提交时才 fallback 到 bundled app-server。其余产品面一律不动。

## 2. 本轮口径（2026-09-25 用户最终确认）

- 两层链路：**Tier 1 = Codex Desktop GUI 自动化；Tier 2 = bundled `codex app-server` stdio**。删除/停用 Remote Control 全部逻辑，不引入 hooks。
- Tier 1 的「成功」**不以按键/AppleScript 事件成功为准**，只以 `~/.codex/thread_history_1.sqlite` 真实持久化为准：发送前记录目标 thread 的 `MAX(rollout_ordinal)`/turn baseline；提交后只有在**目标 thread** 出现 `rollout_ordinal > baseline`、文本与 prompt 一致的新 `userMessage`，且新 `turnId` 状态为 `inProgress`/`completed`，才判 `confirmedSuccess`。
- `failed`/`interrupted` = Desktop 已收到 prompt 但执行失败 → 禁止重复发送；misroute（同文本进了别的 thread）= 明确失败禁止重试；暂时查不到 = `uncertain` → 保持 pending 继续 reconciliation，绝不盲目重试、绝不立即 Tier 2。
- 硬约束：**GUI Tier 1 对某 thread 确认完成前，Tier 2 不得对同一 thread 做任何写操作**（引擎顺序执行保证；Codex 自带跨进程 thread writer lock 兜底）。
- Tier 2 仅在 GUI 明确「未提交任何 prompt」时启用。
- 手动「立即继续」**无额度许可门**（用户显式点击即授权），同样走 GUI → Tier 2。
- git 提交已获用户授权（本轮起自主提交）。

## 3. 已验证的本机事实（新会话不必重测）

| 事实 | 证据/结论 |
|---|---|
| bundled runtime | `/Applications/ChatGPT.app/Contents/Resources/codex`，`codex-cli 0.155.0-alpha.16.4` ✓ |
| stdio app-server | initialize/initialized/rateLimits/read/turns/list/turn-start 全部实测 ✓（会话一） |
| `ordinaryUsageAllowed` | 唯一恢复许可依据；当前账号 primary 100% 限速中，19:11 恢复 ✓ |
| **ChatGPT Desktop 是 Electron**（kimi-cu `is_electron: true`，pid 62242） | 窗口 AX 树浅层全为 AXGroup/AXWebArea；**AX 客户端附着的瞬间树未物化** → Tier 1 第 1 轮 AX 语义聚焦失败属预期，点击回退后 focused 节点的 `AXTextArea`（title=随心输入）+ `AXValue` 可读。`AXManualAccessibility`/`AXEnhancedUserInterface` 设置返回 -25205/-25208 不可用，但无需设置：树随客户端访问异步物化 |
| composer 几何 | `AXTextArea [422,732 713x44]` value=继续；中心 y≈754 > 窗口 803 的中点 401、宽 713 ≥ 40% —— 过滤条件可通过，第 1 轮失败是树未物化而非条件不匹配 |
| **限速时 Desktop 禁用提交**（用户截图实证） | 额度用尽时发送按钮置灰，Cmd+Enter 无效，粘贴正常 → 限速窗口 GUI Tier 1 必然「提交未生效」，这是产品语义不是故障。且 composer 会留下未发送残留 |
| 深链冷启动 | `NSWorkspace.open` 只代表 LaunchServices 接受请求；E2E 时 Desktop 已在运行，`isFinishedLaunching` 轮询通过；冷启动分支（urlForApplication → openApplication → 15s）未实测（会话四可补） |
| config.toml | sha256 = `248e1d1c0b63f0576446e77c415facd238bd7304fddb29ade4055f7375d581ad`（本轮前后一致 ✓；remote_control 读写已删除，本 App 不再碰 config.toml） |
| **辅助功能授权与 ad-hoc 签名**（2026-09-25 实证） | **ad-hoc 每次重签指纹都变，授权绑定旧指纹即「反复勾仍显示未授权」**；本机未装 LaunchAgent 时旧的「授权后 kickstart 重启」静默失败（已修复为直接重开自身）。**最终方案：回退 ad-hoc、弃用自签名证书**（用户决定，本机自用不折腾）；正确授权路径 = 最后一次安装后系统设置→辅助功能→「+」添加 App→勾选。重装后需重勾一次（已授权状态：面板显示已授权 ✓） |
| 旧 control socket 路线 | **整体废弃**（daemon 从未启动、socket 不存在、connectionCount=0 恒成立，会话二已证伪） |
| FileHandle 管道读回归 | macOS 26 上 `FileHandle.read(upToCount:)` 阻塞读不唤醒；StdioTransport 用 POSIX read(2)（会话二修复，保持） |

## 4. 本轮改造内容（会话三，8 改 1 新增 1 归档）

- `GUIContinuation.swift`（新增，583 行）：GUI Tier 1 完整事务——Preflight（AX+PostEvent 权限、SQLite baseline，拒绝盲发）→ Navigate（deep link → isFinishedLaunching 轮询 → 冷启动兜底 → activate+isActive 轮询，3 轮）→ Focus（AX 树候选过滤[下半部/≥40% 宽/非搜索框]+打分+SetFocused+CFEqual 验证；点击窗口底部回退且验证 role/enabled）→ Paste+Submit（剪贴板快照/defer 恢复、Cmd+V 校验、Cmd+Enter、1s 复读仅重按一次、**残留检测**：相同内容跳过粘贴、其它内容拒绝覆盖）→ Reconcile（0.5/1/2/4/8s 五轮查 `thread_items`/`thread_turns`，misroute 排查，最终 composer 复读三态裁定）
- `AutoContinueEngine.swift`（重写）：两层状态机；`GUIContinuationResult` 三态路由——confirmedSuccess→handled；delivered:true→不标 handled、禁 Tier 2、明确通知；delivered:false→Tier 2 接管；uncertain→`.gui` pending（10 分钟无落盘视为未提交清除）后续轮询 DB 补查。Tier 2 通道逻辑不变（resume+turn/start、RPC 对账、turn 监控释放 writer 锁）。`guiSender` 接缝供测试注入
- `SQLiteReader.swift`：删除 `CodexConfig`（remote_control 读写）；新增 `SubmissionBaseline`/`SubmissionEvidence`/`captureSubmissionBaseline`/`findSubmissionEvidence`/`findPossibleMisroute`/`userMessageText`（只读，不改 schema）
- `AppModel.swift`：删除 remoteControlEnabled/setRemoteControl/upgradeToTier1IfHealthy/authoritativeClient（额度通道简化为单一 Tier 2）；`continueThread` 新签名（无 primaryClient）；手动继续无额度门
- `AppServerManager.swift`：删除 probeDesktopControl/controlSocketPath/controlSocketExists
- `AppServerClient.swift`：Tier 枚举删 `tier1RemoteControl`
- `AppServerTransport.swift`：删除 `WebSocketTransport`（Tier 1 WS）
- `SettingsPanelView.swift`：删除 remote_control toggle
- `WebSocketClient.swift` → `.archive/`（gitignore，不追踪）

## 5. 验收记录（2026-09-25 会话三）

1. **mock 自测 55/55 全绿**：客户端 9 + DB 回执单测 11 + 引擎矩阵 18 + 环境/其他。DB 单测（fakehome fixture）：baseline 捕获/证据匹配(inProgress/failed)/文本不匹配/ordinal 边界/多 part 拼接/misroute 命中与排除/时间窗。引擎矩阵：GUI 成功不启动 Tier2、GUI 未提交→Tier2、**GUI delivered:true→禁 Tier2 不标 handled**、GUI uncertain→pending→DB 补查 found/failed/无记录三态、Tier2 ambiguous→unreadable→pending→found、absent→下轮重发、无头不调 GUI、两层失败。编译：`swiftc -O main.swift + 仓库 8 文件`
2. **真实 GUI E2E ×2（临时 thread `01a0d813-2a5f-7573-8518-8a2ba45aa0dd`）**：
   - E2E#1：激活✓ 聚焦（点击回退）✓ 粘贴✓（AXValue 校验通过）→ 提交未生效（限速置灰）→ DB 确认零落盘 → `uncertain`。**回执通道如实工作，无误报成功**
   - E2E#2（残留路径）：检测到 composer 残留「继续」== command → 跳过粘贴直接提交 → 仍置灰 → 最终复读可读含原文 → `confirmedFailure(delivered:false)`「允许 Tier 2 接管」
3. **安装**：备份 `/tmp/CodexReset.app.bak-20260925-182526` → ad-hoc 签名 ✓ → app 内 `--query` 正常（own-server、13 暂停对话、config 哈希一致）
4. **GUI 实测**：菜单栏「⏳ 46分钟」→ 面板显示上限/13 暂停对话/自动继续开关/指令框/无 remote_control 项/「辅助功能未授权」提示（ad-hoc 重签预期内，用户点「授权」重授）

### 剩余（按优先级）

1. **19:11 额度恢复后 confirmed 路径实证**（已排程）：对临时 thread 重跑 `--e2e`，期望 `confirmedSuccess`（turn 真实运行，消耗极小额度）→ 全链路闭环。若用户已对新 app 勾选对话，真实 auto-continue 本身就是终极验收
2. GUI 无权限路径（e07 类）本机 SKIP（Bash 子进程有 AX 权限；代码路径已人工核对）
3. 冷启动分支（Desktop 未运行时）未实测；首次真实运行大概率覆盖
4. 「输入框已有其它未发送内容」分支未实测（需要人工在 composer 放草稿的场景，路径简单已 review）

## 6. 新会话接手指引

1. 读本文件 + `AGENTS.md`；`git log` 看三个 commit（上游 base → 会话一二 → 会话三）
2. 自测套件：`/tmp/codex-reset-selftest/`（易失；main.swift 支持 `--e2e <threadId> <command>` 真实 GUI 事务模式；fake_codex.py 支持 `turn/start模式,turns/list模式` 两段式 mode）
3. 临时测试 thread：`01a0d813-2a5f-7573-8518-8a2ba45aa0dd`（title「E2E自测对话：请只回复 ok」，用完可删）
4. 若协议/行为与本文件第 3 节冲突：停下报告，不自行扩大改造
