import Foundation

final class KimiUsageProvider: UsageProviderService {
    static let shared = KimiUsageProvider()
    let provider: Provider = .kimi
    private let service: KimiAPIService

    init(service: KimiAPIService? = nil) { self.service = service ?? KimiAPIService() }

    func hasCredentials(for profile: Profile) -> Bool { profile.kimiAPIKey?.nilIfBlank != nil }

    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        try await fetchResult(for: profile, active: false).usage
    }

    func fetchResult(for profile: Profile, active: Bool) async throws -> UsageProviderResult {
        guard let key = profile.kimiAPIKey?.nilIfBlank else {
            throw AppError(code: .providerCredentialsNotFound, message: "kimi.error.key".localized, isRecoverable: true)
        }
        let snapshot = try await service.fetchUsage(apiKey: key, region: profile.kimiConfiguration.region)
        return UsageProviderResult(usage: snapshot.sharedUsage(configuration: profile.kimiConfiguration),
            projectUsage: { snapshot.sharedUsage(configuration: $0.kimiConfiguration) })
    }
}
