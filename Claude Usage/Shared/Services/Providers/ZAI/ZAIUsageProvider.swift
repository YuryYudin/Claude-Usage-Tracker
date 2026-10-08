import Foundation

final class ZAIUsageProvider: UsageProviderService {
    static let shared = ZAIUsageProvider()
    let provider: Provider = .zai
    private let service: ZAIAPIService

    init(service: ZAIAPIService = ZAIAPIService()) { self.service = service }

    func hasCredentials(for profile: Profile) -> Bool { profile.zaiAPIKey?.nilIfBlank != nil }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        try await fetchResult(for: profile, active: false).usage
    }

    func fetchResult(for profile: Profile, active: Bool) async throws -> UsageProviderResult {
        guard let key = profile.zaiAPIKey else { throw ZAIAPIServiceError.invalidKey("") }
        let snapshot = try await service.fetchUsage(apiKey: key)
        return UsageProviderResult(usage: snapshot.sharedUsage(configuration: profile.zaiConfiguration), updateDetails: { profile in
            profile.zaiUsage = snapshot
        }, projectUsage: { current in
            snapshot.sharedUsage(configuration: current.zaiConfiguration)
        })
    }
}

extension ZAIUsage {
    func sharedUsage(configuration: ZAIProfileConfiguration) -> ClaudeUsage {
        var result = ClaudeUsage.empty
        result.weeklyLimit = 0
        let quotas: [UsageQuota] = rateLimits.compactMap { limit in
            guard let window = limit.primary else { return nil }
            let role: UsageQuota.Role = limit.isFiveHourSessionWindow ? .session
                : (limit.isWeeklyWindow ? .weekly : (limit.kind == .toolCalls ? .tools : .other))
            return UsageQuota(id: limit.id, bucketID: "zai", label: limit.displayName, role: role,
                usedPercentage: window.usedPercent, resetTime: window.resetsAt,
                durationMinutes: window.windowDurationMinutes, consumed: window.usedCredits,
                allowance: window.totalCredits, unit: limit.kind == .toolCalls ? "calls" : "credits")
        }
        let session = quotas.first { $0.role == .session }
        let weekly = quotas.first { $0.role == .weekly }
        result.sessionAvailable = session != nil
        result.weeklyAvailable = weekly != nil
        result.sessionPercentage = session?.usedPercentage ?? 0
        result.sessionResetTime = session?.resetTime ?? .distantFuture
        result.weeklyPercentage = weekly?.usedPercentage ?? 0
        result.weeklyResetTime = weekly?.resetTime ?? .distantFuture
        result.quotaWindows = quotas
        result.selectedQuotaID = rateLimit(preferredID: configuration.selectedLimitID)?.id
        result.planType = account?.planType
        result.lastUpdated = lastUpdated
        return result
    }
}
