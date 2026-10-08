import Foundation

final class CodexAppServerProvider: UsageProviderService {
    static let shared = CodexAppServerProvider()
    let provider: Provider = .codex
    private var clients: [UUID: CodexAppServerService] = [:]

    func hasCredentials(for profile: Profile) -> Bool {
        profile.codexConfiguration?.validationError == nil
            && profile.codexConfiguration != nil
    }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        try await fetchResult(for: profile, active: false).usage
    }

    func fetchResult(for profile: Profile, active: Bool) async throws -> UsageProviderResult {
        guard let config = profile.codexConfiguration else {
            throw AppError(code: .providerCredentialsNotFound, message: "Select a Codex connection", isRecoverable: true)
        }
        let client: CodexAppServerService = await MainActor.run {
            if let client = clients[profile.id] { return client }
            let client = CodexAppServerService()
            clients[profile.id] = client
            return client
        }
        let snapshot = try await client.fetchUsage(configuration: config)
        return UsageProviderResult(usage: snapshot.sharedUsage(configuration: config), updateDetails: { profile in
            profile.codexUsage = snapshot
        }, projectUsage: { current in
            snapshot.sharedUsage(configuration: current.codexConfiguration ?? config)
        })
    }

    func retainClients(for profiles: [Profile]) {
        let ids = Set(profiles.filter { $0.codexConfiguration != nil && $0.provider == .codex }.map(\.id))
        for id in Array(clients.keys) where !ids.contains(id) {
            clients.removeValue(forKey: id)?.stop()
        }
    }
}

extension CodexUsage {
    func sharedUsage(configuration: CodexProfileConfiguration) -> ClaudeUsage {
        var result = ClaudeUsage.empty
        result.weeklyLimit = 0
        let selected = rateLimit(preferredID: configuration.selectedRateLimitID)
        let quotas: [UsageQuota] = rateLimits.flatMap { limit in
            [("primary", limit.primary), ("secondary", limit.secondary)].compactMap { slot, window in
                guard let window else { return nil }
                let role: UsageQuota.Role = window.windowDurationMinutes == 10080 ? .weekly
                    : (window.windowDurationMinutes == 300 ? .session : (slot == "primary" ? .session : .weekly))
                return UsageQuota(id: "\(limit.id):\(slot)", bucketID: limit.id, label: limit.displayName,
                    role: role, usedPercentage: window.usedPercent, resetTime: window.resetsAt,
                    durationMinutes: window.windowDurationMinutes, unit: nil)
            }
        }
        let selectedQuotas = quotas.filter { $0.bucketID == selected?.id }
        let session = selectedQuotas.first { $0.role == .session }
        let weekly = selectedQuotas.first { $0.role == .weekly }
        result.sessionAvailable = session != nil
        result.weeklyAvailable = weekly != nil
        result.sessionPercentage = session?.usedPercentage ?? 0
        result.sessionResetTime = session?.resetTime ?? .distantFuture
        result.weeklyPercentage = weekly?.usedPercentage ?? 0
        result.weeklyResetTime = weekly?.resetTime ?? .distantFuture
        result.quotaWindows = quotas
        result.selectedQuotaID = session?.id ?? weekly?.id
        result.planType = selected?.planType ?? account?.planType
        result.creditsUnlimited = selected?.credits?.unlimited
        result.creditsBalance = selected?.credits?.balance.flatMap(Double.init)
        result.lastUpdated = lastUpdated
        return result
    }
}
