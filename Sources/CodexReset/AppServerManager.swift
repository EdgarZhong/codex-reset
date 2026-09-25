import Foundation

/// 管理控制链路的 Tier 2 通道：本 App 自起的 `codex app-server`
/// （stdio JSON-RPC，lazy 启动，独占持有进程）。
/// Tier 1 GUI 自动化在 GUIContinuationController / AutoContinueEngine 内，不经本类。
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

    /// 发现并记录 runtime（幂等；只记录第一次结果）
    func resolveRuntime() {
        guard runtimePath == nil else { return }
        guard let rt = CodexRuntime.discover() else { return }
        runtimePath = rt.path
        runtimeVersion = CodexRuntime.version(at: rt.path)
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
