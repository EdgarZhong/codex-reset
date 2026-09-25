import Foundation

/// 用量窗口（primary=5小时，secondary=1周）
struct RateLimitWindow: Decodable {
    /// 已用百分比 0-100
    let usedPercent: Int
    /// 恢复时间（Unix 秒）
    let resetsAt: Int?
    /// 窗口时长（分钟）：300=5小时, 10080=1周
    let windowDurationMins: Int?
}

/// 点数余额
struct CreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

/// 单个限额快照
struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
    /// rate_limit_reached / workspace_owner_usage_limit_reached 等
    let rateLimitReachedType: String?
    let spendControlReached: Bool?
}

/// account/rateLimits/read 响应
struct AccountRateLimits: Decodable {
    /// backend 对「ordinary included usage 已允许」的肯定判断。
    /// true=明确允许；false=明确不允许；nil=服务端未提供该字段（不可用于推断恢复）
    let ordinaryUsageAllowed: Bool?
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

/// 额度是否已恢复到「可以自动发送 continuation」的判定。
///
/// 唯一许可依据是 backend 的明确肯定：
///   ordinaryUsageAllowed == true
///   AND rateLimitReachedType == nil 或 "none"
///   AND spendControlReached != true
/// usedPercent 只用于界面展示；resetsAt 还用于识别 primary 5h 窗口 rollover。
/// 两者都不授予发送许可。
enum QuotaRecovery {
    enum Decision: Equatable {
        /// 明确允许发送
        case allowed
        /// 明确仍不可恢复
        case blocked(reason: String)
        /// 服务端未给出判断依据，不允许据此宣布恢复
        case unknown(reason: String)

        var isAllowed: Bool { self == .allowed }

        /// 供日志展示的原因文本
        var reasonText: String {
            switch self {
            case .allowed: return "allowed"
            case .blocked(let r): return r
            case .unknown(let r): return r
            }
        }
    }

    static func decision(_ rl: AccountRateLimits) -> Decision {
        guard let allowed = rl.ordinaryUsageAllowed else {
            return .unknown(reason: "服务端未返回 ordinaryUsageAllowed，无法确认恢复")
        }
        guard allowed else {
            return .blocked(reason: "ordinaryUsageAllowed=false")
        }
        if let reached = rl.rateLimits.rateLimitReachedType, reached != "none" {
            return .blocked(reason: "rateLimitReachedType=\(reached)")
        }
        if rl.rateLimits.spendControlReached == true {
            return .blocked(reason: "spendControlReached=true")
        }
        return .allowed
    }

    static func isAllowed(_ rl: AccountRateLimits) -> Bool {
        decision(rl).isAllowed
    }
}

/// 跟踪 primary 5h 窗口 rollover。首次观测只建立 baseline；后续每次 resetsAt 变化
/// 产生一个待处理 trigger，只有 QuotaRecovery 明确允许时才能消费。
struct PrimaryWindowResetTracker {
    enum Observation: Equatable {
        case baseline
        case unchanged
        case rollover
    }

    private(set) var lastResetsAt: Int?
    private(set) var pendingRollovers = 0

    mutating func observe(resetsAt: Int) -> Observation {
        guard let previous = lastResetsAt else {
            lastResetsAt = resetsAt
            return .baseline
        }
        guard previous != resetsAt else { return .unchanged }
        lastResetsAt = resetsAt
        pendingRollovers += 1
        return .rollover
    }

    /// 每次只消费一个 rollover，重复轮询不会再次消费同一个 trigger。
    mutating func consumePendingIfAllowed(_ rateLimits: AccountRateLimits) -> Bool {
        guard pendingRollovers > 0, QuotaRecovery.decision(rateLimits).isAllowed else {
            return false
        }
        pendingRollovers -= 1
        return true
    }
}

// MARK: - 线程相关

/// thread/read 返回的线程信息
struct ThreadInfo: Decodable {
    let id: String
    let name: String?
    let preview: String?
    let cwd: String?
    let path: String?
    let source: String?
    let status: ThreadStatus?
    let updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, preview, cwd, path, source, status, updatedAt
    }

    struct ThreadStatus: Decodable {
        let type: String
    }
}

struct ThreadReadResult: Decodable {
    let thread: ThreadInfo
}

/// turn/start 响应。
/// 手动解析（而非 Decodable 强解码）：响应里可能有 error 对象等嵌套结构，
/// 一旦强解码失败会把「可能已提交」误判成失败。
struct TurnStartResult {
    let turnId: String
    let status: String
    /// turn.error.message（若有）
    let errorMessage: String?

    /// 服务端是否已接受这次 prompt
    var isAccepted: Bool {
        !turnId.isEmpty && (status == "inProgress" || status == "completed")
    }

    static func parse(_ dict: [String: Any]) -> TurnStartResult? {
        guard let turn = dict["turn"] as? [String: Any] else { return nil }
        let errorMessage = (turn["error"] as? [String: Any])?["message"] as? String
        return TurnStartResult(
            turnId: turn["id"] as? String ?? "",
            status: turn["status"] as? String ?? "",
            errorMessage: errorMessage
        )
    }
}

/// thread/turns/list 分页结果（reconciliation 用：确认某次 continuation 是否真的进入了 thread）
struct TurnPage {
    /// 每个元素是一个 turn：{ id, status, items: [ {type, clientId, ...}, ... ] }
    let turns: [[String: Any]]

    init(_ dict: [String: Any]) {
        turns = dict["data"] as? [[String: Any]] ?? []
    }

    /// 在最近若干 turn 的 userMessage item 中查找 clientId 匹配的条目，命中则返回所属 turn id
    func turnId(matchingClientId clientId: String) -> String? {
        guard !clientId.isEmpty else { return nil }
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items where (item["type"] as? String) == "userMessage" {
                if (item["clientId"] as? String) == clientId {
                    return turn["id"] as? String
                }
            }
        }
        return nil
    }
}

// MARK: - 用量历史

/// 一次 5 小时用量窗口（时间线上的一个点）
struct UsageResetEvent: Codable, Identifiable {
    let id: UUID
    /// 窗口开始时间（= 上次重置点）
    let windowStart: Date
    /// 下次重置时间
    let nextResetAt: Date
    /// 记录时的用量百分比
    let usedPercent: Double
    /// 检测到的时间
    let detectedAt: Date

    init(windowStart: Date, nextResetAt: Date, usedPercent: Double, detectedAt: Date = Date()) {
        self.id = UUID()
        self.windowStart = windowStart
        self.nextResetAt = nextResetAt
        self.usedPercent = usedPercent
        self.detectedAt = detectedAt
    }
}
