import Foundation

/// Presentation edits do not cancel refreshes; account/transport edits do.
struct ProfileAccountIdentity: Equatable {
    let id: UUID
    let provider: Provider
    let source: [String?]

    init(_ profile: Profile) {
        id = profile.id
        provider = profile.provider
        switch provider {
        case .anthropic:
            source = [profile.claudeSessionKey, profile.organizationId,
                      profile.apiSessionKey, profile.apiOrganizationId,
                      profile.customKeychainServiceName,
                      Self.claudeAccount(profile)]
        case .codex:
            if let config = profile.codexConfiguration {
                source = [config.connectionType.rawValue, config.executablePath?.nilIfBlank,
                          config.codexHome?.nilIfBlank, config.sshHost?.nilIfBlank]
            } else if let json = profile.codexCredentialsJSON {
                let credentials = CodexAuthService.parse(Data(json.utf8))
                source = ["http", credentials?.resolvedAccountId
                          ?? credentials.flatMap { Self.subject($0.accessToken) } ?? json]
            } else {
                source = ["http-file", Self.authFileRevision()]
            }
        case .zai:
            source = [profile.zaiAPIKey]
        case .unsupported(let raw):
            source = [raw]
        }
    }

    private static func subject(_ token: String) -> String? {
        CodexAuthService.decodeJWTPayload(token)?["sub"] as? String
    }

    private static func claudeAccount(_ profile: Profile) -> String? {
        if let json = profile.oauthAccountJSON,
           let account = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let id = account["accountUuid"] as? String { return id }
        guard let json = profile.cliCredentialsJSON else { return nil }
        if let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           let sub = subject(token) { return sub }
        return json
    }

    private static func authFileRevision() -> String? {
        guard !AppEnvironment.isTesting else { return nil }
        guard let credentials = try? CodexAuthService.shared.loadFromAuthFile() else { return nil }
        return credentials.resolvedAccountId ?? subject(credentials.accessToken) ?? credentials.accessToken
    }
}
