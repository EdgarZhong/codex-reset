import Foundation
import SQLite3

/// 运行：swiftc -parse-as-library Sources/CodexReset/Models.swift \
///   Sources/CodexReset/SQLiteReader.swift Tests/CodexResetTests/PrimaryWindowResetAndSQLiteReaderTests.swift \
///   -o /tmp/codex-reset-window-tests && /tmp/codex-reset-window-tests
@main
struct PrimaryWindowResetAndSQLiteReaderTests {
    enum FixtureError: Error {
        case sqlite(String)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func makeRateLimits(ordinaryAllowed: Bool?, usedPercent: Int, resetsAt: Int) -> AccountRateLimits {
        AccountRateLimits(
            ordinaryUsageAllowed: ordinaryAllowed,
            rateLimits: RateLimitSnapshot(
                limitId: "codex",
                limitName: "primary",
                primary: RateLimitWindow(usedPercent: usedPercent, resetsAt: resetsAt,
                                         windowDurationMins: 300),
                secondary: nil,
                credits: nil,
                planType: nil,
                rateLimitReachedType: "none",
                spendControlReached: false
            ),
            rateLimitsByLimitId: nil
        )
    }

    static func testFirstObservationOnlyEstablishesBaseline() {
        var tracker = PrimaryWindowResetTracker()
        expect(tracker.observe(resetsAt: 1_000) == .baseline, "first observation is baseline")
        expect(!tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: true, usedPercent: 12,
                                                               resetsAt: 1_000)),
               "startup baseline must not trigger")
        expect(tracker.pendingRollovers == 0, "baseline leaves no pending trigger")
    }

    static func testRolloverTriggersBelowExhaustion() {
        var tracker = PrimaryWindowResetTracker()
        _ = tracker.observe(resetsAt: 1_000)
        expect(tracker.observe(resetsAt: 1_300) == .rollover, "changed resetsAt is rollover")
        expect(tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: true, usedPercent: 37,
                                                              resetsAt: 1_300)),
               "allowed rollover triggers before 100% usage")
        expect(tracker.pendingRollovers == 0, "allowed trigger is consumed")
    }

    static func testDelayedOrdinaryUsageAllowanceKeepsTriggerPending() {
        var tracker = PrimaryWindowResetTracker()
        _ = tracker.observe(resetsAt: 1_000)
        _ = tracker.observe(resetsAt: 1_300)
        expect(!tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: false, usedPercent: 61,
                                                               resetsAt: 1_300)),
               "false allowance does not trigger")
        expect(!tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: nil, usedPercent: 61,
                                                               resetsAt: 1_300)),
               "missing allowance does not trigger")
        expect(tracker.pendingRollovers == 1, "blocked rollover remains pending")
        expect(tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: true, usedPercent: 61,
                                                              resetsAt: 1_300)),
               "later confirmed allowance triggers pending rollover")
        expect(!tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: true, usedPercent: 61,
                                                               resetsAt: 1_300)),
               "consumed trigger cannot fire again")
    }

    static func testSameRolloverFiresOnceAndNextRolloverFiresAgain() {
        var tracker = PrimaryWindowResetTracker()
        _ = tracker.observe(resetsAt: 1_000)
        _ = tracker.observe(resetsAt: 1_300)
        let allowed = makeRateLimits(ordinaryAllowed: true, usedPercent: 9, resetsAt: 1_300)
        expect(tracker.consumePendingIfAllowed(allowed), "first rollover fires")
        expect(tracker.observe(resetsAt: 1_300) == .unchanged, "same reset is unchanged")
        expect(!tracker.consumePendingIfAllowed(allowed), "same rollover does not fire twice")
        expect(tracker.observe(resetsAt: 1_600) == .rollover, "next 5h window creates another rollover")
        expect(tracker.consumePendingIfAllowed(makeRateLimits(ordinaryAllowed: true, usedPercent: 14,
                                                              resetsAt: 1_600)),
               "next rollover fires again for the still-selected cycle")
    }

    static func execute(_ sql: String, at path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite("could not open fixture database at \(path)")
        }
        defer { sqlite3_close(database) }

        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(error)
            throw FixtureError.sqlite(message)
        }
    }

    static func testHistoricalLimitFailureIsHiddenAfterNewerSuccessfulTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexResetWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyPath = directory.appendingPathComponent("thread_history_1.sqlite").path
        let statePath = directory.appendingPathComponent("state_5.sqlite").path
        try execute("""
            CREATE TABLE thread_turns (
                thread_id TEXT, turn_id TEXT, status TEXT, error_json TEXT, started_at INTEGER
            );
            INSERT INTO thread_turns VALUES
                ('stale-thread', '0001', 'failed', '{"message":"usageLimitExceeded"}', 100);
            INSERT INTO thread_turns VALUES
                ('stale-thread', '0002', 'completed', NULL, 200);
            INSERT INTO thread_turns VALUES
                ('currently-paused', '0003', 'failed', '{"message":"usageLimitExceeded"}', 300);
            """, at: historyPath)
        try execute("""
            CREATE TABLE threads (
                id TEXT, title TEXT, cwd TEXT, updated_at INTEGER,
                updated_at_ms INTEGER, archived INTEGER, source TEXT
            );
            INSERT INTO threads VALUES ('stale-thread', 'Stale task', '', 200, 200, 0, 'local');
            INSERT INTO threads VALUES ('currently-paused', 'Paused task', '', 300, 300, 0, 'local');
            """, at: statePath)

        let ids = SQLiteReader(codexHome: directory.path).usageLimitedThreads().map(\.threadId)
        expect(ids == ["currently-paused"], "only latest failed usageLimitExceeded turn is paused")
    }

    static func main() throws {
        testFirstObservationOnlyEstablishesBaseline()
        testRolloverTriggersBelowExhaustion()
        testDelayedOrdinaryUsageAllowanceKeepsTriggerPending()
        testSameRolloverFiresOnceAndNextRolloverFiresAgain()
        try testHistoricalLimitFailureIsHiddenAfterNewerSuccessfulTurn()
        print("PrimaryWindowReset/SQLiteReader: 5 tests passed")
    }
}
