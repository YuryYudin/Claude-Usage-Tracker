import Foundation

@MainActor
final class CodexTokenRefreshCoordinator {
    typealias Refresh = (CodexCredentials) async throws -> CodexCredentials
    private let fetch: Refresh
    private let rotations = OAuthRefreshCoordinator<CodexCredentials>(rotatedToken: { $0.refreshToken })

    init(fetch: @escaping Refresh) { self.fetch = fetch }

    func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        try await rotations.value(for: credentials.refreshToken) { try await self.fetch(credentials) }
    }
}
