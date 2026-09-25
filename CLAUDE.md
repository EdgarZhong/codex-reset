# CodexReset 兼容性改造 — 进度同步与 Handoff

> 动态文档，随推进更新。规则与边界见 `AGENTS.md`。最后更新：2026-09-25（会话二结束，验收完成）

## 1. 当前目标（唯一核心）

当 Codex 订阅额度恢复时，可靠地向用户勾选的既有 Codex thread 发送当前全局 continuation prompt。其余产品面一律不动。

## 2. 任务来源与硬边界

用户已下发完整对齐方案（ Remote Control first + bundled stdio fallback + 新版 quota 语义 ）。关键边界：

- 不改 UI/设置页/对话列表/双击打开/全局 prompt 控件/GUI fallback 实现/SQLite/launchagent
- 不新增依赖、不重写架构、不装 standalone CLI、不动 Codex config/auth/Desktop
- 构建产物替换 `/Applications/CodexReset.app`（替换前备份旧 App 到 /tmp，构建失败不得破坏现有版本）
- 验收只读，**不得向真实 thread 发送 prompt**
- 任何协议假设若与本机 runtime 实测冲突：保留证据、停下报告，不自行扩大范围

## 3. 已验证的本机事实（新会话不必重测）

探测脚本在 `/tmp/codex-reset-probe/`（易失，重启后需重写；结论已记录在此）。
自测套件在 `/tmp/codex-reset-selftest/`（fake_codex.py + main.swift + 编译说明见本文件第 4 节；易失）。

| 事实 | 证据/结论 |
|---|---|
| bundled runtime | `/Applications/ChatGPT.app/Contents/Resources/codex`，版本 `codex-cli 0.155.0-alpha.16.4`，可执行 ✓ |
| bundle 发现 | `NSWorkspace.urlsForApplications(withBundleIdentifier: "com.openai.codex")` 返回 ChatGPT.app ✓（真机 ObjC 验证） |
| stdio app-server | `codex app-server`（不带 --listen）走换行分隔 JSON-RPC，initialize/initialized/rateLimits/read/turns/list 全部实测成功 ✓ |
| `ordinaryUsageAllowed` | `account/rateLimits/read` 顶层返回该字段（实测 `false`，当前账号 primary 100% 已限速）✓ |
| `thread/turns/list` | 支持 `limit/sortDirection/itemsView`；返回 `data[]`，turn 含 `id/status/items[]`；userMessage item 含 `clientId` ✓ |
| `clientUserMessageId` | `turn/start` 接受**任意字符串**（非 UUID、`codexreset-<uuid>` 均通过校验；仅校验 string 类型）。对账标记用 `codexreset-<UUID>` ✓ |
| `thread/resume` | 支持 `excludeTurns: true`（官方推荐路径，二进制字符串确认）；对已加载线程返回 `already has an active writer` JSON-RPC error（明确失败）✓ |
| control socket | 路径 `$CODEX_HOME/app-server-control/app-server-control.sock`（CLI `daemon version` 实测确认）。**根因（2026-09-25 排查）：socket 由 `codex app-server daemon` 子命令管理，daemon 从未启动过，故不存在；ChatGPT 桌面日志显示 `remoteControl/enable` 成功但 connectionCount=0，桌面 UI 开关 ≠ 创建 socket**。会话一「重启 Codex 出 socket」假设已证伪（14:31 重启后仍无）。启用路径（须用户自己执行，安全边界禁止本 App bootstrap）：`codex app-server daemon bootstrap` → `daemon start`（daemon 启动后会读 config 的 remote_control=true 开 socket）；CodexReset 下轮轮询会自动热切换 Tier 1，无需重启 |
| 本机 config | `~/.codex/config.toml` sha256 = `248e1d1c0b63f0576446e77c415facd238bd7304fddb29ade4055f7375d581ad`（验收前后一致 ✓） |
| LaunchAgent | 无 CodexReset LaunchAgent（只有 com.dvcrn.codex-oauth-proxy），无需处理 |
| **FileHandle 管道读回归** | **macOS 26.7（25G229）上 `FileHandle.read(upToCount:)` 对子进程管道的阻塞读在数据到达时永不唤醒**（osascript 环境复现，非 harness 独有）；POSIX `read(2)` 同 fd 正常。`StdioTransport.readLoop` 已改用 `read(2)`（AppServerTransport.swift，EINTR 重试）。stderr 的 `readabilityHandler` 不受影响，保持原样 |
| 自测结论 | 客户端级 8 项 + 引擎级 14 断言全部通过（29/29），覆盖：fallback 顺序、ambiguous→对账→不盲发、handledThreads 语义、超时摘除/断连 drain/迟到丢弃 |

## 4. 当前进展状态

**全部剩余工作已完成（2026-09-25 会话二）：mock 自测 29/29 全绿 → `--query` 无头验收通过 → 已备份并替换 /Applications/CodexReset.app（ad-hoc 签名 ✓）→ GUI 面板实测正常。git 仍未提交，等待用户决定是否提交。**

### 会话二新增：生产 bug 修复（自测的最大收获）

- **bug**：`StdioTransport.readLoop` 用 `FileHandle.read(upToCount:)` 阻塞读子进程 stdout。在 macOS 26.7 上该 API 对已阻塞的管道读**在数据到达时不唤醒**，导致 Tier 2 完全不可用（真实 `CodexReset --query` 也复现："initialize 请求超时"）。上一会话仅通过 python 脚本直连验证过协议，从未走过 `StdioTransport`，故未发现。
- **修复**：改用 POSIX `read(handle.fileDescriptor,...)`（同一 fd、阻塞语义不变、EINTR 重试），注释已说明原因。修复后 `--query` 与 fake server 全链路正常。
- **教训**：协议验证 ≠ 组件验证；新写的传输层必须端到端跑一次真实子进程。

### 会话一已完成（8 个源文件）

- `Sources/CodexReset/CodexRuntime.swift`（新增）：runtime 发现，顺序 = CODEX_CLI_PATH → NSWorkspace bundle 查询 → /Applications/ChatGPT.app → Codex.app → standalone 路径；全部 `isExecutableFile` 校验；`--version` 探测带 10s 超时
- `Sources/CodexReset/AppServerTransport.swift`（新增）：`AppServerTransport` 协议 + `WebSocketTransport`（Tier 1）+ `StdioTransport`（Tier 2，stdio，独占持有进程，close 时只终止自己的子进程：先关 stdin → SIGTERM → SIGKILL；**会话二修复：readLoop 用 POSIX read**）
- `Sources/CodexReset/WebSocketClient.swift`（改）：握手 8s 超时（`withSocketTimeout` 看门狗关 fd 打断阻塞读）、`isOpen`、`close()` 单次回调语义
- `Sources/CodexReset/AppServerClient.swift`（重写）：每请求 timeout（initialize 8s / healthRead 10s / resume 15s / turnStart 20s / listTurns 15s）；transport 关闭立即 drain 所有 pending 抛 `RPCTransportError.connectionClosed`；timeout 后摘除 pending，迟到响应丢弃不二次 resume；新增 `tier` 与 `isInitialized`
- `Sources/CodexReset/AppServerManager.swift`（重写）：`probeDesktopControl()` 完整健康探测；`startOwnServer()` lazy stdio + 复用；已删除 `codexBinaryPath()` 旧逻辑、freePort/pingReady、`--listen` 模式
- `Sources/CodexReset/AutoContinueEngine.swift`（重写）：三态状态机 `ContinuationOutcome`（confirmed/definitiveFailure/uncertain）；ambiguous → `reconcileSubmission`（preferred → Tier1 只读重连 → Tier2，3 次读取 × 2.5s 间隔）；`pendingReconciliations` + `resolvePendingReconciliations()`；GUI fallback 仅在 definitiveFailure 且无 uncertain 时进入；`isBusy` 供热切换避让；已删除 onNeedRestartCodex 重启引导
- `Sources/CodexReset/Models.swift`（改）：`AccountRateLimits.ordinaryUsageAllowed: Bool?`；`QuotaRecovery.decision`（allowed/blocked/unknown + reasonText）；`TurnStartResult` 手动解析；`TurnPage.turnId(matchingClientId:)`
- `Sources/CodexReset/AppModel.swift`（改）：删除 broad pkill；删除重启提示；`refreshChannelAndUsage()` 统一通道维护；`authoritativeRateLimits()`；`checkRecovery` 改用 QuotaRecovery 许可门；`trackWindowReset` 改用 `windowDurationMins * 60`；headless query 增加 ordinaryUsageAllowed 输出

### 验收记录（2026-09-25 会话二）

1. **mock 自测 29/29 全绿**：`/tmp/codex-reset-selftest/`（易失）。编译命令：`swiftc -O -o selftest main.swift <仓库 7 个 swift 文件>`（Models/WebSocketClient/AppServerTransport/AppServerClient/AppServerManager/CodexRuntime/AutoContinueEngine）。客户端级：往返/JSON-RPC 错误/超时摘除+迟到丢弃/断连 drain/握手+通知。引擎级（fake_codex.py 为真子进程，模式文件驱动 ok/resume-error/start-error/hang-start/found/absent/unreadable）：Tier1 成功不启动 Tier2、Tier1 明确失败→Tier2 顺序、ambiguous→对账 found→不重发、absent→才允许下一层、unreadable→保持 pending 不重发、补查 found/absent 语义、GUI 分支许可门。e07（GUI 无权限路径）因本机已授辅助功能权限而 SKIP（有副作用风险）
2. **`--query` 无头验收**：`mode=own-server`、`ordinaryUsageAllowed=false`（账号在限速中，符合预期）、primary 100%/300min、secondary 53%/10080min、`reached=rate_limit_reached`、`lastError=nil`
3. **替换安装**：备份 `/tmp/CodexReset.app.bak-20260925-170805` → `./make_app.sh` → ad-hoc 签名 ✓（`codesign -dv` 验证）；替换后 app 内 `--query` 复测通过；config.toml 哈希前后一致
4. **GUI 实测**：菜单栏项"⏳ 2小时1分"（AX help="Codex 用量监控"）；面板显示"已到用量上限 · 2小时1分后恢复"、5h 100%（19:11 恢复）、1w 53%、plus、点数 0、暂停对话 13、自动继续开关、全局 prompt 控件、无重启提示；"辅助功能未授权"提示符合预期（ad-hoc 重签后授权失效，用户点「授权」重授即可）
5. **进程隔离**：运行中的 CodexReset 只持有自己的 `codex app-server` 子进程；ChatGPT 桌面自己的 app-server 未被触碰

### 剩余（收尾）

1. 用户确认后 git commit（AGENTS.md 边界：未获明确要求不提交）
2. README fork 说明（待用户拍板是否要写）
3. 上游观察：配额恢复后自动 continuation 的真实端到端发送仍未经实测（当前账号 100% 限速；逻辑由对账语义保证，恢复时建议观察一轮）

### 已知警告（不阻塞，Swift 6 才报错）

- `AppServerClient`/`AutoContinueEngine` 中 NSLock 在 async 上下文使用（Swift 5.9 仅警告；锁内操作极短，风险可接受）
- `WebSocketClient.withSocketTimeout` 的 `finished` 跨线程捕获为数据竞争（Bool，仅看门狗用，实际无害；若在意可改 NSLock 保护）

## 5. 新会话接手指引

1. 读本文件 + `AGENTS.md`；方案要点见上方第 2 节
2. `git status && git diff --stat` 确认工作区状态（应有 6 改 + 4 新增：2 源文件 + AGENTS.md + CLAUDE.md）
3. 若需重跑自测：按第 4 节验收记录第 1 条的 swiftc 命令编译 `/tmp/codex-reset-selftest/`（目录易失，文件内容需按第 4 节描述重建）
4. 若协议实测与本文件第 3 节冲突：停下报告，不自行扩大改造
