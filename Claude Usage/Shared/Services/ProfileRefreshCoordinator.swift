import Foundation

@MainActor
final class ProfileRefreshCoordinator {
    enum Outcome {
        case updated(UsageProviderResult)
        case failed(Error)
        case superseded
    }

    typealias Fetch = (Profile, Bool) async throws -> UsageProviderResult
    private var generations: [UUID: UUID] = [:]
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { profile, active in
        try await ProviderRegistry.service(for: profile.provider).fetchResult(for: profile, active: active)
    }) { self.fetch = fetch }

    var isRefreshing: Bool { !generations.isEmpty }
    func isRefreshing(_ id: UUID) -> Bool { generations[id] != nil }

    func refresh(_ profile: Profile, active: Bool,
                 isCurrent: (ProfileAccountIdentity) -> Bool) async -> Outcome {
        let identity = ProfileAccountIdentity(profile)
        let generation = UUID()
        generations[profile.id] = generation
        defer {
            if generations[profile.id] == generation { generations.removeValue(forKey: profile.id) }
        }
        do {
            let result = try await fetch(profile, active)
            guard generations[profile.id] == generation, isCurrent(identity) else { return .superseded }
            return .updated(result)
        } catch {
            guard generations[profile.id] == generation, isCurrent(identity) else { return .superseded }
            return .failed(error)
        }
    }
}
