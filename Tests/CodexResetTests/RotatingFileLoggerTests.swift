import Foundation

/// 运行：swiftc -parse-as-library Sources/CodexReset/RotatingFileLogger.swift \
///   Tests/CodexResetTests/RotatingFileLoggerTests.swift -o /tmp/codex-reset-logger-tests && /tmp/codex-reset-logger-tests
@main
struct RotatingFileLoggerTests {
    static func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexResetLoggerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func testRotationKeepsNewestRecordsWithinTotalLimit(_ directory: URL) throws {
        let logger = RotatingFileLogger(directory: directory, maxFileBytes: 32, maxFiles: 3)
        for index in 0..<10 { try logger.append(String(format: "event-%02d", index)) }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("codex-reset.log") }.sorted()
        expect(names == ["codex-reset.log", "codex-reset.log.1", "codex-reset.log.2"], "archive names")
        var records: [String] = []
        for name in names.reversed() {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            expect(data.count <= 32, "archive exceeds 32 bytes")
            records += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        expect(records == (3..<10).map { String(format: "event-%02d", $0) }, "newest records")
    }

    static func testLongUnicodeRecordAndNewlinesStayInsideOneFile(_ directory: URL) throws {
        let logger = RotatingFileLogger(directory: directory, maxFileBytes: 16, maxFiles: 1)
        try logger.append("你好\n" + String(repeating: "界", count: 20))
        let data = try Data(contentsOf: directory.appendingPathComponent("codex-reset.log"))
        expect(data.count <= 16, "long event exceeds file limit")
        expect(String(data: data, encoding: .utf8) != nil, "invalid UTF-8")
        expect(data.last == 0x0A, "missing newline")
        try logger.append("next")
        let next = try String(contentsOf: directory.appendingPathComponent("codex-reset.log"), encoding: .utf8)
        expect(next == "next\n", "single file rotation")
    }

    static func testSeparateInstancesShareRotationLock(_ directory: URL) throws {
        let first = RotatingFileLogger(directory: directory, maxFileBytes: 64, maxFiles: 2)
        let second = RotatingFileLogger(directory: directory, maxFileBytes: 64, maxFiles: 2)
        let group = DispatchGroup()
        let errors = NSLock()
        var failures: [Error] = []
        for index in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try (index.isMultiple(of: 2) ? first : second).append("event-\(index)") }
                catch {
                    errors.lock()
                    failures.append(error)
                    errors.unlock()
                }
            }
        }
        group.wait()
        expect(failures.isEmpty, "concurrent write failed")
        for name in ["codex-reset.log", "codex-reset.log.1"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            expect(data.count <= 64, "concurrent archive exceeds 64 bytes")
            expect(String(data: data, encoding: .utf8) != nil, "concurrent archive invalid UTF-8")
        }
    }

    static func testExistingPermissivePathsAreRestricted(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let log = directory.appendingPathComponent("codex-reset.log")
        FileManager.default.createFile(atPath: log.path, contents: Data("old\n".utf8),
                                       attributes: [.posixPermissions: 0o644])
        try RotatingFileLogger(directory: directory).append("new")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let logMode = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
        expect(directoryMode?.intValue == 0o700, "directory permissions")
        expect(logMode?.intValue == 0o600, "log permissions")
    }

    static func main() throws {
        try withDirectory(testRotationKeepsNewestRecordsWithinTotalLimit)
        try withDirectory(testLongUnicodeRecordAndNewlinesStayInsideOneFile)
        try withDirectory(testSeparateInstancesShareRotationLock)
        try withDirectory(testExistingPermissivePathsAreRestricted)
        print("RotatingFileLogger: 4 tests passed")
    }
}
