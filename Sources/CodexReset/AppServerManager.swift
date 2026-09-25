import Foundation

/// 管理三层控制通道中的前两层：
/// - Tier 1：桌面 Codex app 的 Remote Control control socket（只复用，不负责启动/维护 daemon）
/// - Tier 2：本 App 自起的 `codex app-server`（stdio JSON-RPC，lazy 启动，独占持有进程）
/// - Tier 3：GUI/Accessibility fallback 在 AutoContinueEngine 内，不经本类
final class AppServerManager {
    let codexHome: String
    private var ownTransport: StdioTransport?
    private var ownClient: AppServerClient?
    /// 实际选中的 codex runtime 路径与版本（日志/验收用）
    private(set) var runtimePath: String?
    private(set) var runtimeVersion: String?

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    /// remote-control 控制 socket 路径（$CODEX_HOME/app-server-control/app-server-control.sock）
    var controlSocketPath: String {
        codexHome + "/app-server-control/app-server-control.sock"
    }

    func controlSocketExists() -> Bool {
        FileManager.default.fileExists(atPath: controlSocketPath)
    }

    /// 发现并记录 runtime（幂等；只记录第一次结果）
    func resolveRuntime() {
        guard runtimePath == nil else { return }
        guard let rt = CodexRuntime.discover() else { return }
        runtimePath = rt.path
        runtimeVersion = CodexRuntime.version(at: rt.path)
    }

    /// Tier 1 完整健康探测：
    /// socket 存在 + Unix connect + WebSocket 握手 + initialize + initialized + rateLimits/read 可解析。
    /// 任何一步失败都不算 healthy（仅 socket 文件存在、remoteControlEnabled 配置都不算可用）。
    /// 成功时返回已就绪的客户端与额度快照。不修改通道归属，由调用方决定。
    func probeDesktopControl() async -> (client: AppServerClient, rateLimits: AccountRateLimits?)? {
        guard controlSocketExists() else { return nil }
        let client = AppServerClient(transport: WebSocketTransport(unixPath: controlSocketPath), tier: .tier1RemoteControl)
        do {
            try client.connect()
            try await client.initialize()
            let dict = try await client.requestDict("account/rateLimits/read")
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let parsed = try? JSONDecoder().decode(AccountRateLimits.self, from: data) else {
                client.close()
                return nil
            }
            return (client, parsed)
        } catch {
            client.close()
            return nil
        }
    }

    /// Tier 2：lazy 启动 bundled codex app-server（stdio，不带 --listen），独占持有并复用。
    /// 只 terminate 本类启动的进程；initialize 由调用方完成。
    func startOwnServer() throws -> AppServerClient {
        if let ownClient, ownClient.isOpen {
            return ownClient
        }
        stopOwnServer()

        resolveRuntime()
        guard let binaryPath = runtimePath else {
            throw StdioTransport.Error.spawnFailed(
                "未找到可用的 codex 可执行文件（CODEX_CLI_PATH / ChatGPT.app / Codex.app / standalone CLI 均不存在）")
        }
        let transport = StdioTransport(binaryPath: binaryPath, codexHome: codexHome)
        let client = AppServerClient(transport: transport, tier: .tier2OwnServer)
        try client.connect()
        ownTransport = transport
        ownClient = client
        return client
    }

    /// 停止本 App 自起的 app-server（只影响自己持有的进程）
    func stopOwnServer() {
        ownClient?.close()
        ownTransport?.close()
        ownClient = nil
        ownTransport = nil
    }
}
