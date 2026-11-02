//
//  UsageProviderService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-07-15.
//

import Foundation

/// The fetch contract every usage provider implements. Resolved through
/// `ProviderRegistry.service(for:)` — call sites never reference a concrete
/// provider type, so new providers plug in without core-file changes.
@MainActor
protocol UsageProviderService {
    var provider: Provider { get }

    /// Whether the profile can fetch usage right now, including any
    /// provider-specific system-level credential fallbacks that only apply
    /// to the active profile.
    func hasCredentials(for profile: Profile) -> Bool

    /// Fetches usage for a specific (possibly non-active) profile using only
    /// that profile's own credentials.
    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage

    /// Fetches usage for the ACTIVE profile. Providers may use a broader
    /// auth chain here (e.g. Anthropic's system-keychain CLI fallback, which
    /// reflects the currently signed-in CLI account and is therefore only
    /// safe for the active profile). Defaults to `fetchUsage(for:)`.
    func fetchUsageForActiveProfile(_ profile: Profile) async throws -> ClaudeUsage
    func fetchStatus() async throws -> ClaudeStatus?
    func fetchResult(for profile: Profile, active: Bool) async throws -> UsageProviderResult
}

extension UsageProviderService {
    func fetchStatus() async throws -> ClaudeStatus? {
        guard let url = provider.descriptor.statusPageURL else { return nil }
        return try await ClaudeStatusService(statusURL: url).fetchStatus()
    }

    func fetchResult(for profile: Profile, active: Bool) async throws -> UsageProviderResult {
        let usage = try await (active ? fetchUsageForActiveProfile(profile) : fetchUsage(for: profile))
        return UsageProviderResult(usage: usage)
    }
    func fetchUsageForActiveProfile(_ profile: Profile) async throws -> ClaudeUsage {
        try await fetchUsage(for: profile)
    }
}

/// Providers may attach a cache update, applied only after account validation.
struct UsageProviderResult {
    var usage: ClaudeUsage
    var updateDetails: (inout Profile) -> Void = { _ in }
    var projectUsage: ((Profile) -> ClaudeUsage)? = nil
}
