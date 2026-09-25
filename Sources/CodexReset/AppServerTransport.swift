import Foundation

/// RPC 传输抽象（Tier 2 bundled app-server 专用）。
/// 当前唯一实现：`StdioTransport` —— 本 App 自己启动的 `codex app-server`
/// （stdin/stdout 换行分隔 JSON-RPC，独占持有子进程）。
/// Tier 1 GUI 自动化不经本协议层。
protocol AppServerTransport: AnyObject {
    /// 收到一行 JSON 文本（已去掉换行）
    var onText: ((String) -> Void)? { get set }
    /// 连接关闭（只会回调一次）
    var onClose: ((Swift.Error?) -> Void)? { get set }
    var isOpen: Bool { get }
    /// 子进程 stderr 尾部等诊断信息
    var diagnosticTail: String { get }

    /// 建立连接（阻塞调用，调用方需保证有超时保护）
    func start() throws
    /// 发送一行 JSON 文本
    func send(_ text: String) throws
    /// 关闭连接；Tier 2 会终止自己启动的子进程
    func close()
}

// MARK: - Tier 2: bundled codex app-server over stdio

/// 以 `<codex> app-server` 启动独立 app-server（不带 --listen），
/// 用 stdin/stdout 传输换行分隔的 JSON-RPC。
/// 本类独占持有该子进程：只会终止自己启动的进程，绝不扫描/清理其它 Codex 进程。
final class StdioTransport: AppServerTransport {
    enum Error: Swift.Error, CustomStringConvertible {
        case spawnFailed(String)
        case closed
        case writeFailed(String)

        var description: String {
            switch self {
            case .spawnFailed(let m): return "app-server 启动失败: \(m)"
            case .closed: return "app-server 连接已关闭"
            case .writeFailed(let m): return "写入 app-server 失败: \(m)"
            }
        }
    }

    private let binaryPath: String
    private let codexHome: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var open = false
    private var closeNotified = false
    private var stderrTail = ""
    private var arguments: [String] = ["app-server"]

    var onText: ((String) -> Void)?
    var onClose: ((Swift.Error?) -> Void)?

    var diagnosticTail: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return stderrTail
    }

    var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard open else { return false }
        return process?.isRunning ?? false
    }

    init(binaryPath: String, codexHome: String?) {
        self.binaryPath = binaryPath
        self.codexHome = codexHome
    }

    func start() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let codexHome { env["CODEX_HOME"] = codexHome }
        // launchd 等最小环境下 PATH 不含 Homebrew/本地 bin，显式补全
        let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = basePath + ":" + (env["PATH"] ?? "")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] _ in
            self?.finishClose(error: nil)
        }

        do {
            try proc.run()
        } catch {
            throw Error.spawnFailed("\(error)")
        }

        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading

        stateLock.lock()
        open = true
        closeNotified = false
        stateLock.unlock()

        // 采集 stderr 尾部，仅用于诊断（不参与协议）
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            self.stateLock.lock()
            self.stderrTail = String((self.stderrTail + text).suffix(4000))
            self.stateLock.unlock()
        }

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "codex-stdio-read"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func send(_ text: String) throws {
        guard isOpen, let handle = stdinHandle else { throw Error.closed }
        guard let payload = (text + "\n").data(using: .utf8) else { throw Error.writeFailed("UTF-8 编码失败") }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try handle.write(contentsOf: payload)
        } catch {
            throw Error.writeFailed("\(error)")
        }
    }

    func close() {
        stateLock.lock()
        let alreadyNotified = closeNotified
        closeNotified = true
        open = false
        stateLock.unlock()
        guard !alreadyNotified else { return }
        terminateOwnedProcess()
        cleanupHandles()
        onClose?(nil)
    }

    // MARK: - 内部

    private func readLoop() {
        guard let handle = stdoutHandle else { return }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            // 不能用 FileHandle.read(upToCount:)：macOS 26 上它对管道的阻塞读在数据到达时不会唤醒
            // （Foundation 回归，2026-09 实测），改用同一 fd 的 POSIX read(2)，阻塞语义不变
            var n: Int
            repeat {
                n = chunk.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            } while n < 0 && errno == EINTR
            guard n > 0 else { break } // 0=EOF：子进程退出或关闭了 stdout；<0=错误
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { onText?(line) }
            }
        }
        finishClose(error: nil)
    }

    /// 统一收尾：只通知一次，并保证子进程不残留
    private func finishClose(error: Swift.Error?) {
        stateLock.lock()
        let alreadyNotified = closeNotified
        closeNotified = true
        open = false
        stateLock.unlock()
        guard !alreadyNotified else { return }
        terminateOwnedProcess()
        cleanupHandles()
        onClose?(error)
    }

    /// 只终止本对象启动的进程：先关 stdin（server 读到 EOF 会自行退出）→ SIGTERM → SIGKILL
    private func terminateOwnedProcess() {
        guard let proc = process, proc.isRunning else { return }

        writeLock.lock()
        try? stdinHandle?.close()
        writeLock.unlock()

        let gracefulDeadline = Date().addingTimeInterval(0.5)
        while proc.isRunning && Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            let terminateDeadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    private func cleanupHandles() {
        stderrHandle?.readabilityHandler = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle = nil
        stdoutHandle = nil
        stdinHandle = nil
        process = nil
    }
}
