//
//  ProviderRegistry.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-07-15.
//

import Foundation

/// The single seam between the app and its usage providers. Everything that
/// needs provider-specific data or behavior resolves it here — descriptors
/// for declarative facts (branding, capabilities), services for fetching.
///
/// Adding a provider = one descriptor entry + one service entry + a folder
/// under `Shared/Services/Providers/<Name>/`. See docs/ADDING_A_PROVIDER.md.
enum ProviderRegistry {

    // MARK: - Descriptors

    private static let descriptors: [Provider: ProviderDescriptor] = [
        .anthropic: ProviderDescriptor(
            id: .anthropic,
            displayName: "Anthropic",
            logoAssetName: "ProviderLogoAnthropic",
            logoSystemSymbolFallback: "sparkle",
            statusPageURL: URL(string: "https://status.claude.com/api/v2/status.json"),
            capabilities: ProviderCapabilities(
                tokenCounts: true,
                perModelBreakdown: true,
                consoleBilling: true,
                cliAccountSync: true,
                autoStartSession: true,
                overageChecks: true,
                credits: false
            ),
            credentialSections: [.claudeAI, .apiConsole, .cliAccount],
            primaryWindowLabelKey: "usage.window.session",
            secondaryWindowLabelKey: "usage.window.weekly"
        ),
        .codex: ProviderDescriptor(
            id: .codex,
            displayName: "OpenAI Codex",
            logoAssetName: "ProviderLogoOpenAI",
            logoSystemSymbolFallback: "circle.hexagongrid",
            statusPageURL: URL(string: "https://status.openai.com/api/v2/status.json"),
            capabilities: ProviderCapabilities(
                tokenCounts: false,
                perModelBreakdown: false,
                consoleBilling: false,
                cliAccountSync: false,
                autoStartSession: false,
                overageChecks: false,
                credits: true
            ),
            credentialSections: [.codexAccount],
            primaryWindowLabelKey: "usage.window.session",
            secondaryWindowLabelKey: "usage.window.weekly"
        ),
        .zai: ProviderDescriptor(
            id: .zai, displayName: "Z.ai GLM", logoAssetName: "ProviderLogoZAI",
            logoSystemSymbolFallback: "z.square.fill", statusPageURL: nil,
            capabilities: ProviderCapabilities(tokenCounts: false, perModelBreakdown: false,
                consoleBilling: false, cliAccountSync: false, autoStartSession: false,
                overageChecks: false, credits: false), credentialSections: [.zaiAccount],
            primaryWindowLabelKey: "usage.window.session", secondaryWindowLabelKey: "usage.window.weekly"
        ),
    ]

    static func descriptor(for provider: Provider) -> ProviderDescriptor {
        guard let descriptor = descriptors[provider] else {
            return ProviderDescriptor(id: provider, displayName: provider.rawValue,
                logoAssetName: "", logoSystemSymbolFallback: "questionmark.circle", statusPageURL: nil,
                capabilities: ProviderCapabilities(tokenCounts: false, perModelBreakdown: false,
                    consoleBilling: false, cliAccountSync: false, autoStartSession: false,
                    overageChecks: false, credits: false), credentialSections: [],
                primaryWindowLabelKey: "usage.window.session", secondaryWindowLabelKey: "usage.window.weekly")
        }
        return descriptor
    }

    // MARK: - Services

    @MainActor
    static func service(for provider: Provider) -> UsageProviderService {
        switch provider {
        case .anthropic:
            return AnthropicUsageProvider.shared
        case .codex:
            return CodexUsageProvider.shared
        case .zai:
            return ZAIUsageProvider.shared
        case .unsupported:
            return UnsupportedUsageProvider()
        }
    }
}

private struct UnsupportedUsageProvider: UsageProviderService {
    var provider: Provider { .unsupported("unknown") }
    func hasCredentials(for profile: Profile) -> Bool { false }
    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        throw AppError(code: .providerCredentialsNotFound, message: "This account's provider is unavailable in this build", isRecoverable: false)
    }
}
