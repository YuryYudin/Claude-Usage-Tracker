import Foundation

/// Deduplicates rotations and retains consumed-token results for late callers.
@MainActor
final class OAuthRefreshCoordinator<Value> {
    private let rotatedToken: (Value) -> String?
    private var inFlight: [String: Task<Value, Error>] = [:]
    private var rotations: [String: Value] = [:]

    init(rotatedToken: @escaping (Value) -> String?) { self.rotatedToken = rotatedToken }

    func value(for token: String, operation: @escaping () async throws -> Value) async throws -> Value {
        if var rotated = rotations[token] {
            var visited: Set<String> = [token]
            while let next = rotatedToken(rotated), visited.insert(next).inserted,
                  let newer = rotations[next] { rotated = newer }
            return rotated
        }
        if let existing = inFlight[token] { return try await existing.value }
        let task = Task { try await operation() }
        inFlight[token] = task
        defer { inFlight.removeValue(forKey: token) }
        let result = try await task.value
        if let next = rotatedToken(result), next != token { rotations[token] = result }
        return result
    }
}
