import Foundation

/// app-server JSON-RPC 错误
struct JSONRPCError: Swift.Error, CustomStringConvertible {
    let code: Int
    let message: String
    let data: Any?

    var description: String {
        if let data = data {
            return "\(message) (data: \(data))"
        }
        return message
    }
}

/// 连接级错误（超时 / 断连）。这类错误意味着「请求是否已被服务端处理」可能不确定，
/// 调用方必须据此区分「明确失败」与「结果未知」。
enum RPCTransportError: Swift.Error, CustomStringConvertible {
    case timeout(method: String)
    case connectionClosed(method: String, underlying: String?)

    var description: String {
        switch self {
        case .timeout(let method):
            return "\(method) 请求超时"
        case .connectionClosed(let method, let underlying):
            if let underlying { return "\(method) 连接已关闭：\(underlying)" }
            return "\(method) 连接已关闭"
        }
    }

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}

/// 基于 AppServerTransport 的 Codex app-server JSON-RPC 客户端。
/// 消息为 JSON-RPC 2.0，但不带 "jsonrpc" 字段；先 initialize 再 initialized。
///
/// 可靠性保证：
/// - 每个请求都有 timeout，不会无限等待；
/// - transport 关闭/子进程退出时，所有 pending 请求立即以 connection-closed 失败；
/// - timeout 后请求从 pending 中移除，迟到的响应会被丢弃（不会二次 resume continuation）。
final class AppServerClient {
    /// 通道层级（用于日志与 fallback 决策）
    enum Tier {
        case tier1RemoteControl
        case tier2OwnServer
        case unknown

        var name: String {
            switch self {
            case .tier1RemoteControl: return "Tier 1（Remote Control）"
            case .tier2OwnServer: return "Tier 2（bundled app-server）"
            case .unknown: return "app-server"
            }
        }
    }

    /// 各阶段默认超时（秒）
    struct Timeouts {
        var initialize: TimeInterval = 8
        var healthRead: TimeInterval = 10
        var threadResume: TimeInterval = 15
        var turnStart: TimeInterval = 20
        var defaultRequest: TimeInterval = 15
        var listTurns: TimeInterval = 15

        static let `default` = Timeouts()
    }

    private let transport: AppServerTransport
    private let timeouts: Timeouts
    let tier: Tier
    private(set) var isInitialized = false
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Swift.Error>] = [:]
    private let lock = NSLock()
    private var closed = false
    private var closeError: Swift.Error?

    /// 收到的服务端通知回调 (method, params)
    var onNotification: ((String, [String: Any]) -> Void)?

    var isOpen: Bool { transport.isOpen }
    var diagnosticTail: String { transport.diagnosticTail }

    init(transport: AppServerTransport, tier: Tier = .unknown, timeouts: Timeouts = .default) {
        self.transport = transport
        self.tier = tier
        self.timeouts = timeouts
        transport.onText = { [weak self] text in self?.handle(text) }
        transport.onClose = { [weak self] error in self?.transportClosed(error) }
    }

    /// 建立连接（阻塞；transport 自身带握手超时）
    func connect() throws {
        try transport.start()
    }

    func close() {
        transport.close()
    }

    /// 协议握手：initialize 请求 + initialized 通知
    func initialize() async throws {
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "CodexReset", "version": "1.0.0"],
            "capabilities": ["experimentalApi": true]
        ], timeout: timeouts.initialize)
        try notify("initialized", params: [:])
        isInitialized = true
    }

    /// 发送请求并等待响应
    func request(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let timeout: TimeInterval
        switch method {
        case "account/rateLimits/read": timeout = timeouts.healthRead
        case "thread/resume": timeout = timeouts.threadResume
        case "turn/start": timeout = timeouts.turnStart
        case "thread/turns/list": timeout = timeouts.listTurns
        default: timeout = timeouts.defaultRequest
        }
        return try await request(method, params: params, timeout: timeout)
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int
        lock.lock()
        if closed {
            let error = closeError
            lock.unlock()
            throw RPCTransportError.connectionClosed(method: method, underlying: error.map { "\($0)" })
        }
        id = nextId
        nextId += 1
        lock.unlock()

        var body: [String: Any] = ["method": method, "id": id]
        if let params { body["params"] = params }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if closed {
                let error = closeError
                lock.unlock()
                cont.resume(throwing: RPCTransportError.connectionClosed(method: method, underlying: error.map { "\($0)" }))
                return
            }
            pending[id] = cont
            lock.unlock()

            do {
                let text = try Self.jsonText(body)
                try transport.send(text)
                #if DEBUG
                FileHandle.standardError.write("[RPC-SENT] \(method) id=\(id)\n".data(using: .utf8)!)
                #endif
                scheduleTimeout(id: id, method: method, timeout: timeout)
            } catch {
                lock.lock()
                pending.removeValue(forKey: id)
                lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }

    /// 发送请求并解码为指定 JSON 字典（不做强类型解码，避免把有效响应判成失败）
    func requestDict(_ method: String, params: [String: Any]? = nil,
                     timeout: TimeInterval? = nil) async throws -> [String: Any] {
        if let timeout {
            return try await request(method, params: params, timeout: timeout)
        }
        return try await request(method, params: params)
    }

    /// 发送通知（无需响应）
    func notify(_ method: String, params: [String: Any]) throws {
        var body: [String: Any] = ["method": method]
        if !params.isEmpty { body["params"] = params }
        try transport.send(Self.jsonText(body))
    }

    // MARK: - 内部

    private static func jsonText(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONRPCError(code: -1, message: "JSON 编码失败", data: nil)
        }
        return text
    }

    /// 请求超时：从 pending 中摘除并抛错。之后迟到的响应会被丢弃。
    private func scheduleTimeout(id: Int, method: String, timeout: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cont = self.pending.removeValue(forKey: id)
            self.lock.unlock()
            cont?.resume(throwing: RPCTransportError.timeout(method: method))
        }
    }

    /// transport 关闭：立即让所有 pending 请求失败
    private func transportClosed(_ error: Swift.Error?) {
        lock.lock()
        closed = true
        closeError = error
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in waiting {
            cont.resume(throwing: RPCTransportError.connectionClosed(method: "request", underlying: error.map { "\($0)" }))
        }
    }

    private func handle(_ text: String) {
        #if DEBUG
        FileHandle.standardError.write("[RPC-RECV] \(text.prefix(200))\n".data(using: .utf8)!)
        #endif
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            FileHandle.standardError.write("[RPC-PARSE-FAIL] \(text.prefix(200))\n".data(using: .utf8)!)
            #endif
            return
        }

        if let method = obj["method"] as? String {
            onNotification?(method, obj["params"] as? [String: Any] ?? [:])
            return
        }
        guard let id = obj["id"] as? Int else { return }

        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()

        // 已被 timeout 摘除的请求：静默丢弃响应，绝不二次 resume
        guard let cont else { return }

        if let error = obj["error"] as? [String: Any] {
            cont.resume(throwing: JSONRPCError(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "未知错误",
                data: error["data"]
            ))
        } else if let result = obj["result"] as? [String: Any] {
            cont.resume(returning: result)
        } else {
            cont.resume(returning: [:])
        }
    }
}
