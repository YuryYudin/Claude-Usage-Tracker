import Foundation

/// A token response may patch only the credential source that initiated it.
enum CredentialRefreshGuard {
    static func canUpdateClaude(_ current: Profile, expected: Profile, replacement: String) -> Bool {
        current.id == expected.id && current.provider == .anthropic && expected.provider == .anthropic
            && current.customKeychainServiceName == expected.customKeychainServiceName
            && current.oauthAccountJSON == expected.oauthAccountJSON
            && (current.cliCredentialsJSON == expected.cliCredentialsJSON || current.cliCredentialsJSON == replacement)
    }
    static func canUpdateCodex(_ current: CodexCredentials, expected: CodexCredentials,
                               replacement: CodexCredentials) -> Bool {
        current.resolvedAccountId == expected.resolvedAccountId
            && (current.refreshToken == expected.refreshToken || current.refreshToken == replacement.refreshToken)
    }

}
