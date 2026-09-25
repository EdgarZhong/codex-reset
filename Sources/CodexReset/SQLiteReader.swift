import Foundation
import SQLite3

/// SQLite 的 SQLITE_TRANSIENT 是 C 宏，Swift 里需手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 从本地 sqlite 定位「因用量用光而暂停」的对话
struct PausedThread {
    let threadId: String
    let title: String
    let cwd: String
    /// 错误消息里的恢复提示原文，如 "try again at 1:17 PM"
    let recoveryHint: String?
    /// 该失败轮次时间（Unix 秒）
    let failedAt: Int
}

/// GUI Tier 1 发送前的目标 thread 基线
struct SubmissionBaseline {
    /// 目标 thread 当前最大 rollout_ordinal（无记录时为 0）
    let maxOrdinal: Int
    /// 发送前已存在的 turn id 集合（用于判定新 turn）
    let turnIds: Set<String>
    /// 尝试开始时间（Unix 毫秒），misroute 排查用
    let attemptStartedAtMs: Int
}

/// 在目标 thread 中找到的本次提交证据
struct SubmissionEvidence {
    let itemId: String
    let turnId: String
    /// 是否属于发送前不存在的新 turn
    let isNewTurn: Bool
    /// thread_turns.status（inProgress/completed/failed/interrupted/…）
    let turnStatus: String
    /// turn 的 error_json（失败时带原因）
    let turnErrorJson: String?
}

final class SQLiteReader {
    let codexHome: String

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    private var threadHistoryPath: String { codexHome + "/thread_history_1.sqlite" }
    private var stateDbPath: String { codexHome + "/state_5.sqlite" }

    /// 找出所有因用量上限(usageLimitExceeded)失败暂停的线程（每线程取最新一次失败）。
    /// thread_turns 中 turn_id 为 ULID，按 turn_id 倒序即按时间倒序。
    func usageLimitedThreads(limit: Int = 20) -> [PausedThread] {
        guard let rows = queryRows(
            path: threadHistoryPath,
            sql: """
            SELECT t.thread_id, t.error_json, t.started_at
            FROM thread_turns t
            JOIN (
                SELECT thread_id, MAX(turn_id) AS max_turn
                FROM thread_turns
                WHERE status = 'failed' AND error_json LIKE '%usageLimitExceeded%'
                GROUP BY thread_id
            ) m ON t.thread_id = m.thread_id AND t.turn_id = m.max_turn
            ORDER BY t.turn_id DESC
            LIMIT ?
            """,
            args: [limit]
        ) else { return [] }

        var result: [PausedThread] = []
        for row in rows {
            let threadId = row[0] as? String ?? ""
            let errorJson = row[1] as? String ?? ""
            let failedAt = row[2] as? Int ?? 0
            guard !threadId.isEmpty else { continue }
            // 过滤子代理线程（主对话派生的 subagent，非用户独立对话，无需单独继续）
            if isSubagentThread(threadId: threadId) { continue }
            let title = displayTitle(threadId: threadId, stateTitle: threadTitle(threadId: threadId))
            let cwd = threadCwd(threadId: threadId) ?? ""
            let hint = Self.extractRecoveryHint(from: errorJson)
            result.append(PausedThread(threadId: threadId, title: title, cwd: cwd,
                                       recoveryHint: hint, failedAt: failedAt))
        }
        return result
    }

    /// 列出所有对话（含未暂停的），按项目分组用；过滤归档与子代理线程，最新在前
    func allThreads(limit: Int = 1000) -> [PausedThread] {
        guard let rows = queryRows(path: stateDbPath, sql: """
            SELECT id, title, cwd, updated_at
            FROM threads
            WHERE archived = 0 AND source NOT LIKE '{"subagent"%'
            ORDER BY updated_at_ms DESC
            LIMIT ?
        """, args: [limit]) else { return [] }

        var result: [PausedThread] = []
        for row in rows {
            let threadId = row[0] as? String ?? ""
            let rawTitle = row[1] as? String
            let cwd = row[2] as? String ?? ""
            let updatedAt = row[3] as? Int ?? 0
            guard !threadId.isEmpty else { continue }
            let title = displayTitle(threadId: threadId, stateTitle: rawTitle)
            result.append(PausedThread(threadId: threadId, title: title, cwd: cwd,
                                       recoveryHint: nil, failedAt: updatedAt))
        }
        return result
    }

    /// 判断是否为子代理线程（state 库 source 以 {"subagent" 开头）
    private func isSubagentThread(threadId: String) -> Bool {
        guard let source = threadSource(threadId: threadId) else { return false }
        return source.trimmingCharacters(in: .whitespaces).hasPrefix(#"{"subagent""#)
    }

    private func threadSource(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT source FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    /// 标题回退：state 库无记录时，从该线程最早一条 userMessage 提取前 40 字作为标题
    private func fallbackTitle(threadId: String) -> String? {
        guard let row = queryRow(path: threadHistoryPath, sql: """
            SELECT item_json
            FROM thread_items
            WHERE thread_id = ? AND item_type = 'userMessage'
            ORDER BY rollout_ordinal ASC
            LIMIT 1
        """, args: [threadId]),
        let json = row[0] as? String,
        let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let content = obj["content"] as? [[String: Any]],
        let first = content.first,
        let text = first["text"] as? String else { return nil }

        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }

    /// 显示用标题：Codex 会把对话标题自动更新为最新一条 userMessage（如自动发送的「继续」），
    /// 导致列表标题变成「继续」等无意义短标题。这里做智能回退：
    /// 优先用 state 标题；若它是无意义的短标题（<=2 字，如「继续」），回退到最早 userMessage（原始任务）。
    private func displayTitle(threadId: String, stateTitle: String?) -> String {
        if let stateTitle, !stateTitle.isEmpty, stateTitle.count >= 3 {
            return stateTitle
        }
        if let fb = fallbackTitle(threadId: threadId), !fb.isEmpty {
            return fb
        }
        return stateTitle ?? "未命名对话"
    }

    private func threadTitle(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT title FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    private func threadCwd(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT cwd FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    /// 从错误 JSON 中提取 "try again at ..." 恢复提示
    static func extractRecoveryHint(from errorJson: String) -> String? {
        guard let data = errorJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String else {
            return nil
        }
        if let range = message.range(of: "try again at ") {
            return String(message[range.upperBound...])
        }
        return nil
    }

    // MARK: - GUI Tier 1 发送回执（baseline / evidence / misroute）

    /// 提交文本匹配：相等或以 command 结尾均视为本次提交。
    /// 追加语义（用户 2026-09-25 裁定）：输入框有残留时直接追加发送，消息文本可能是「草稿+command」。
    static func matchesCommand(_ text: String?, command want: String) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text == want || text.hasSuffix(want)
    }

    /// 发送前记录目标 thread 基线。DB 不可读返回 nil（调用方应放弃 GUI 发送）。
    func captureSubmissionBaseline(threadId: String) -> SubmissionBaseline? {
        guard let row = queryRow(path: threadHistoryPath,
                                 sql: "SELECT COALESCE(MAX(rollout_ordinal),0) FROM thread_items WHERE thread_id = ?",
                                 args: [threadId]),
              let turnRows = queryRows(path: threadHistoryPath,
                                       sql: "SELECT turn_id FROM thread_turns WHERE thread_id = ?",
                                       args: [threadId]) else {
            return nil
        }
        let turnIds = Set(turnRows.compactMap { $0[0] as? String })
        return SubmissionBaseline(maxOrdinal: row[0] as? Int ?? 0,
                                  turnIds: turnIds,
                                  attemptStartedAtMs: Int(Date().timeIntervalSince1970 * 1000))
    }

    /// 在目标 thread 查找 rollout_ordinal > baseline 且文本一致的新 userMessage，
    /// 命中后附上其 turn 的当前状态。未命中返回 nil（注意：nil ≠ 未提交，可能只是投影延迟）。
    func findSubmissionEvidence(threadId: String, baseline: SubmissionBaseline, command: String) -> SubmissionEvidence? {
        let want = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty,
              let rows = queryRows(path: threadHistoryPath, sql: """
                  SELECT item_id, turn_id, rollout_ordinal, item_json
                  FROM thread_items
                  WHERE thread_id = ? AND item_type = 'userMessage' AND rollout_ordinal > ?
                  ORDER BY rollout_ordinal ASC
                  """, args: [threadId, baseline.maxOrdinal]) else {
            return nil
        }
        for row in rows {
            guard let itemId = row[0] as? String,
                  let turnId = row[1] as? String,
                  let json = row[3] as? String,
                  Self.matchesCommand(Self.userMessageText(json), command: want) else { continue }
            var status = "", errorJson: String? = nil
            if let trow = queryRow(path: threadHistoryPath,
                                   sql: "SELECT status, error_json FROM thread_turns WHERE thread_id = ? AND turn_id = ?",
                                   args: [threadId, turnId]) {
                status = trow[0] as? String ?? ""
                errorJson = trow[1] as? String
            }
            return SubmissionEvidence(itemId: itemId, turnId: turnId,
                                      isNewTurn: !baseline.turnIds.contains(turnId),
                                      turnStatus: status, turnErrorJson: errorJson)
        }
        return nil
    }

    /// misroute 排查：attemptStartedAtMs 之后其它 thread 出现相同文本的新 userMessage。
    /// 命中返回 (threadId, turnId)；无命中返回 nil。
    func findPossibleMisroute(afterMs: Int, command: String, excludingThreadId: String) -> (threadId: String, turnId: String)? {
        let want = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty,
              let rows = queryRows(path: threadHistoryPath, sql: """
                  SELECT thread_id, turn_id, item_json
                  FROM thread_items
                  WHERE thread_id != ? AND item_type = 'userMessage' AND created_at_ms >= ?
                  ORDER BY created_at_ms ASC
                  """, args: [excludingThreadId, afterMs]) else {
            return nil
        }
        for row in rows {
            guard let threadId = row[0] as? String,
                  let turnId = row[1] as? String,
                  let json = row[2] as? String,
                  Self.matchesCommand(Self.userMessageText(json), command: want) else { continue }
            return (threadId, turnId)
        }
        return nil
    }

    /// 从 userMessage 的 item_json 提取完整文本（所有 text part 拼接后去首尾空白）
    static func userMessageText(_ itemJson: String) -> String? {
        guard let data = itemJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "userMessage",
              let content = obj["content"] as? [[String: Any]] else {
            return nil
        }
        return content.compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 通用查询

    private func queryRow(path: String, sql: String, args: [Any] = []) -> [Any?]? {
        queryRows(path: path, sql: sql, args: args)?.first
    }

    /// 多行查询
    private func queryRows(path: String, sql: String, args: [Any] = []) -> [[Any?]]? {
        guard let db = open(path) else {
            #if DEBUG
            FileHandle.standardError.write("[SQLITE-OPEN-FAIL] \(path)\n".data(using: .utf8)!)
            #endif
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            #if DEBUG
            let err = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "?"
            FileHandle.standardError.write("[SQLITE-PREPARE-FAIL] \(err)\n".data(using: .utf8)!)
            #endif
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            if let s = arg as? String {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            } else if let n = arg as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }

        let count = sqlite3_column_count(stmt)
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: [Any?] = []
                for i in 0..<count {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row.append(Int(sqlite3_column_int64(stmt, i)))
                    case SQLITE_TEXT:
                        if let c = sqlite3_column_text(stmt, i) {
                            row.append(String(cString: c))
                        } else {
                            row.append(nil)
                        }
                    case SQLITE_NULL:
                        row.append(nil)
                    case SQLITE_FLOAT:
                        row.append(sqlite3_column_double(stmt, i))
                    default:
                        if let c = sqlite3_column_text(stmt, i) {
                            row.append(String(cString: c))
                        } else {
                            row.append(nil)
                        }
                    }
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                #if DEBUG
                let err = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "rc=\(rc)"
                FileHandle.standardError.write("[SQLITE-STEP-FAIL] \(err)\n".data(using: .utf8)!)
                #endif
                return nil
            }
        }
        return rows
    }

    private func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // 用 READWRITE 而非 READONLY：WAL 模式数据库在并发写时 readonly 打开可能失败
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK else {
            let msg = (db.flatMap { sqlite3_errmsg($0) }).flatMap { String(cString: $0) } ?? "rc=\(rc)"
            #if DEBUG
            FileHandle.standardError.write("[SQLITE-OPEN-ERR] \(path): \(msg)\n".data(using: .utf8)!)
            #endif
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }
}

// Remote Control 已废弃（2026-09 本轮转向）：CodexReset 不再读写 ~/.codex/config.toml 的 [features] remote_control。
