import Foundation

enum KimiRegion: String, Codable, CaseIterable {
    case global, china

    var usageURL: URL {
        URL(string: self == .global ? "https://api.kimi.ai/coding/v1/usages" : "https://api.kimi.com/coding/v1/usages")!
    }

    var integrationID: String { self == .global ? "kimi-code-plan-global" : "kimi-code-plan-cn" }
    var title: String { self == .global ? "Kimi.ai" : "Kimi.com" }
}

struct KimiProfileConfiguration: Codable, Equatable {
    var region: KimiRegion = .global
    var selectedQuotaID: String?
}

/// A fetched snapshot, independent of the profile's current tray selection.
struct KimiUsage {
    let quotas: [UsageQuota]
    let lastUpdated: Date

    func sharedUsage(configuration: KimiProfileConfiguration) -> ClaudeUsage {
        var usage = ClaudeUsage.unavailable
        let session = quotas.first { $0.role == .session }
        let weekly = quotas.first { $0.role == .weekly }
        usage.weeklyLimit = 0
        usage.sessionAvailable = session != nil
        usage.weeklyAvailable = weekly != nil
        usage.sessionPercentage = session?.usedPercentage ?? 0
        usage.sessionResetTime = session?.resetTime ?? .distantFuture
        usage.weeklyPercentage = weekly?.usedPercentage ?? 0
        usage.weeklyResetTime = weekly?.resetTime ?? .distantFuture
        usage.quotaWindows = quotas
        usage.selectedQuotaID = quotas.first { $0.id == configuration.selectedQuotaID }?.id
        usage.lastUpdated = lastUpdated
        return usage
    }
}

enum KimiError: LocalizedError, Equatable {
    case invalidResponse, importFailed, ambiguousAccounts, retryLater

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "kimi.error.response".localized
        case .importFailed: return "kimi.error.import".localized
        case .ambiguousAccounts: return "kimi.error.ambiguous".localized
        case .retryLater: return "kimi.error.retry".localized
        }
    }
}
