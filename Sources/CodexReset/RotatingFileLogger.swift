import Foundation
import Darwin

/// 持久化运行日志。当前文件加 4 个归档文件，每个文件不超过 1 MiB。
/// 每次写入都持有文件锁，避免 GUI 与无头命令并行运行时交错写入或互相覆盖轮转结果。
final class RotatingFileLogger {
    static let shared = RotatingFileLogger()

    static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs/CodexReset", isDirectory: true)
    }

    let directory: URL
    let maxFileBytes: Int
    let maxFiles: Int
    private let processLock = NSLock()
    private let fileName = "codex-reset.log"

    init(directory: URL = RotatingFileLogger.defaultDirectory,
         maxFileBytes: Int = 1_048_576,
         maxFiles: Int = 5) {
        precondition(maxFileBytes >= 16 && maxFiles >= 1)
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
    }

    func append(_ message: String) throws {
        // 一条事件占一行；超长事件按 UTF-8 字符边界截断，单条也不能突破文件上限。
        let singleLine = message.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        var bytes = Data(singleLine.utf8)
        if bytes.count >= maxFileBytes {
            bytes = Data(bytes.prefix(maxFileBytes - 1))
            while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        }
        bytes.append(0x0A)

        processLock.lock()
        defer { processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
        let lockPath = directory.appendingPathComponent(".codex-reset.lock").path
        let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw posixError() }
        defer { _ = Darwin.close(lockFD) }
        guard fchmod(lockFD, 0o600) == 0 else { throw posixError() }
        guard flock(lockFD, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = flock(lockFD, LOCK_UN) }

        let current = directory.appendingPathComponent(fileName).path
        var fd = Darwin.open(current, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else { throw posixError() }
        if fchmod(fd, 0o600) != 0 {
            let error = posixError()
            _ = Darwin.close(fd)
            throw error
        }
        let size = lseek(fd, 0, SEEK_END)
        if size < 0 {
            let error = posixError()
            _ = Darwin.close(fd)
            throw error
        }
        if size + off_t(bytes.count) > off_t(maxFileBytes) {
            _ = Darwin.close(fd)
            try rotate()
            fd = Darwin.open(current, O_CREAT | O_WRONLY | O_APPEND | O_TRUNC, 0o600)
            guard fd >= 0 else { throw posixError() }
        }
        defer { _ = Darwin.close(fd) }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
    }

    private func rotate() throws {
        let files = FileManager.default
        func path(_ index: Int) -> String {
            let suffix = index == 0 ? "" : ".\(index)"
            return directory.appendingPathComponent(fileName + suffix).path
        }
        if maxFiles == 1 {
            if files.fileExists(atPath: path(0)) { try files.removeItem(atPath: path(0)) }
            return
        }
        if files.fileExists(atPath: path(maxFiles - 1)) {
            try files.removeItem(atPath: path(maxFiles - 1))
        }
        for index in stride(from: maxFiles - 2, through: 0, by: -1) {
            if files.fileExists(atPath: path(index)) {
                try files.moveItem(atPath: path(index), toPath: path(index + 1))
            }
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
