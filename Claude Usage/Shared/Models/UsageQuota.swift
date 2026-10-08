import Foundation

/// Extra quota windows retain their identity, units and reset availability.
struct UsageQuota: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case session, weekly, tools, other }
    var id: String
    var bucketID: String
    var label: String
    var role: Role
    var usedPercentage: Double
    var resetTime: Date?
    var durationMinutes: Int?
    var consumed: Double?
    var allowance: Double?
    var unit: String?

    var effectivePercentage: Double { effectivePercentage(at: Date()) }

    func effectivePercentage(at date: Date) -> Double {
        if let resetTime, resetTime <= date { return 0 }
        return usedPercentage
    }
}

extension ClaudeUsage {
    var primaryQuota: UsageQuota? {
        if let selectedQuotaID, let selected = quotaWindows?.first(where: { $0.id == selectedQuotaID }) {
            return selected
        }
        return quotaWindows?.first(where: { $0.role == .session })
            ?? quotaWindows?.first(where: { $0.role == .weekly })
            ?? quotaWindows?.first
    }

    /// Tray selection does not alter the actual session/weekly history values.
    var trayUsage: ClaudeUsage {
        var result = self
        if let quota = primaryQuota {
            result.sessionPercentage = quota.effectivePercentage
            result.sessionResetTime = quota.resetTime ?? .distantFuture
        } else if sessionAvailable == false, weeklyAvailable != false {
            result.sessionPercentage = weeklyPercentage
            result.sessionResetTime = weeklyResetTime
        }
        return result
    }
}
