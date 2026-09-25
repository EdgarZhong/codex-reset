import Foundation
import AppKit

/// 本机 Codex runtime（`codex` 可执行文件）的发现与版本探测。
///
/// 本机可能没有 standalone CLI，因此优先使用 Codex/ChatGPT 桌面 app bundle 自带的二进制：
/// `<App>.app/Contents/Resources/codex`，它同样能作为独立 stdio app-server 使用，
/// 并复用当前 CODEX_HOME 中的登录态。
enum CodexRuntime {
    enum Source: String {
        case envOverride = "CODEX_CLI_PATH"
        case appBundle = "app-bundle"
        case standalone = "standalone-cli"
    }

    struct Runtime {
        let path: String
        let source: Source
    }

    /// 桌面 app 的 bundle identifier（官方 Codex 桌面端）
    static let codexBundleIdentifier = "com.openai.codex"

    /// 发现顺序：显式 CODEX_CLI_PATH → 桌面 app bundle → standalone CLI
    static func discover() -> Runtime? {
        for candidate in candidates() where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// 候选来源列表（已按优先级排序，未做可执行校验）
    static func candidates() -> [Runtime] {
        var list: [Runtime] = []

        // 0) 人工 override
        if let override = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append(Runtime(path: override, source: .envOverride))
        }

        // 1) 通过 NSWorkspace 查 bundle identifier（不依赖安装路径）
        for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: codexBundleIdentifier) {
            list.append(Runtime(path: url.appendingPathComponent("Contents/Resources/codex").path,
                                source: .appBundle))
        }

        // 2) 常见安装位置
        list.append(Runtime(path: "/Applications/ChatGPT.app/Contents/Resources/codex", source: .appBundle))
        list.append(Runtime(path: "/Applications/Codex.app/Contents/Resources/codex", source: .appBundle))

        // 3) 最后才是 standalone CLI（含历史 vendor 路径）
        list.append(Runtime(path: "/opt/homebrew/bin/codex", source: .standalone))
        list.append(Runtime(path: "/usr/local/bin/codex", source: .standalone))
        list.append(Runtime(path: "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
                            source: .standalone))
        return list
    }

    /// 执行 `<codex> --version` 并返回首行（失败返回 nil）
    static func version(at path: String, timeout: TimeInterval = 10) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }

        // 子进程不退出时不要挂死：到点终止
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine
    }
}
