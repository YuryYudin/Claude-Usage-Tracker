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
    var widgetLabelKey: String? = nil

    var effectivePercentage: Double { effectivePercentage(at: Date()) }

    func effectivePercentage(at date: Date) -> Double {
        if let resetTime, resetTime <= date { return 0 }
        return usedPercentage
    }
}

extension ClaudeUsage {
    static var unavailable: ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionAvailable = false
        usage.weeklyAvailable = false
        return usage
    }

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
    var hasPrimaryReset: Bool {
        if let primaryQuota { return primaryQuota.resetTime != nil }
        return sessionAvailable != false || weeklyAvailable != false
    }

    func primaryElapsedFraction(showRemaining: Bool = false) -> Double? {
        if let quota = primaryQuota { return elapsedFraction(for: quota, showRemaining: showRemaining) }
        if sessionAvailable == false { return weeklyElapsedFraction(showRemaining: showRemaining) }
        return UsageStatusCalculator.elapsedFraction(resetTime: sessionResetTime,
            duration: Constants.sessionWindow, showRemaining: showRemaining)
    }

    func weeklyElapsedFraction(showRemaining: Bool = false) -> Double? {
        if let quotas = quotaWindows {
            guard let weekly = quotas.first(where: {
                $0.role == .weekly && (primaryQuota == nil || $0.bucketID == primaryQuota?.bucketID)
            }) else { return nil }
            return elapsedFraction(for: weekly, showRemaining: showRemaining)
        }
        guard weeklyAvailable != false else { return nil }
        return UsageStatusCalculator.elapsedFraction(resetTime: weeklyResetTime,
            duration: Constants.weeklyWindow, showRemaining: showRemaining)
    }

    private func elapsedFraction(for quota: UsageQuota, showRemaining: Bool) -> Double? {
        guard let reset = quota.resetTime, let minutes = quota.durationMinutes, minutes > 0 else { return nil }
        return UsageStatusCalculator.elapsedFraction(resetTime: reset,
            duration: Double(minutes) * 60, showRemaining: showRemaining)
    }

}

extension Profile {
    /// Empty account caches must not inherit another account's global usage or
    /// advertise the placeholder five-hour window as a fetched quota.
    var usageForDisplay: ClaudeUsage {
        claudeUsage ?? .unavailable
    }
}
