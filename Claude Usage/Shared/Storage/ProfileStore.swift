//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Manages storage and retrieval of profiles and profile-related data
class ProfileStore {
    static let shared = ProfileStore()

    private let defaults: UserDefaults
    private let keychainService: ProfileSecretStore
    private let backupDirectory: URL
    private let historyDirectory: URL
    var preferences: UserDefaults { defaults }
    private var loadedData: Data?
    private var originalRecords: [UUID: [String: Any]] = [:]
    private var originalProfiles: [UUID: Profile] = [:]
    private(set) var hasUnreadableProfiles = false
    private(set) var lastPersistenceError: String?

    private enum Keys {
        static let profiles = "profiles_v3"
        static let activeProfileId = "activeProfileId"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
    }

    /// One-time flag so the expected no-keychain-store situation on ad-hoc dev
    /// builds is logged once, not on every save cycle.
    private static var loggedNoKeychainStoreOnce = false

    init(defaults: UserDefaults = .appStorage, secrets: ProfileSecretStore? = nil,
         backupDirectory: URL = AppEnvironment.applicationSupport.appendingPathComponent("migration"),
         historyDirectory: URL = AppEnvironment.applicationSupport.appendingPathComponent("history")) {
        self.defaults = defaults
        self.keychainService = secrets ?? (AppEnvironment.isTesting
            ? MemoryProfileSecretStore() as ProfileSecretStore : KeychainService.shared)
        self.backupDirectory = backupDirectory
        self.historyDirectory = historyDirectory
    }

    // MARK: - Profile Management

    @discardableResult
    func saveProfiles(_ profiles: [Profile]) -> Bool {
        // Never overwrite an unreadable or externally changed store.
        guard !hasUnreadableProfiles else { return false }
        guard defaults.data(forKey: Keys.profiles) == loadedData else {
            lastPersistenceError = "Account storage changed. Reload before saving."
            return false
        }
        do {
            guard Set(profiles.map(\.id)).count == profiles.count else {
                throw NSError(domain: "ProfileStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Duplicate profile identifiers"])
            }
            // Validate all known fields before changing credential storage.
            let stagingEncoder = JSONEncoder()
            stagingEncoder.userInfo[Profile.includeSecretsKey] = true
            let stagingData = try stagingEncoder.encode(profiles)
            _ = try JSONDecoder().decode([Profile].self, from: stagingData)
            if !defaults.bool(forKey: "providerCompatibility_v1") {
                try backupBeforeMigration()
            }
            var allSecretsSaved = true
            for profile in profiles {
                allSecretsSaved = try persistSecrets(of: profile) && allSecretsSaved
            }
            let encoder = JSONEncoder()
            if !allSecretsSaved { encoder.userInfo[Profile.includeSecretsKey] = true }
            let encoded = try encoder.encode(profiles)
            let records = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
            let merged = zip(profiles, records).map { profile, record -> [String: Any] in
                var existing = originalRecords[profile.id] ?? [:]
                for key in Profile.CodingKeys.allCases { existing.removeValue(forKey: key.rawValue) }
                existing.merge(record) { _, new in new }
                return existing
            }
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            let check = try JSONDecoder().decode([Profile].self, from: data)
            guard check.map(\.id) == profiles.map(\.id) else { return false }
            defaults.set(data, forKey: Keys.profiles)
            guard defaults.data(forKey: Keys.profiles) == data else {
                throw NSError(domain: "ProfileStore", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Profile write verification failed"])
            }
            loadedData = data
            originalProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            originalRecords = Dictionary(uniqueKeysWithValues: zip(profiles.map(\.id), merged))
            if allSecretsSaved { defaults.set(true, forKey: "providerCompatibility_v1") }
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error.localizedDescription
            LoggingService.shared.logStorageError("saveProfiles", error: error)
            return false
        }
    }

    private func backupBeforeMigration() throws {
        let manager = FileManager.default
        let filename = "before-provider-integration.plist"
        let url = backupDirectory.appendingPathComponent(filename)
        if manager.fileExists(atPath: url.path) {
            // A corrupt/incomplete backup must never authorize a migration.
            let backup = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            guard let dictionary = backup as? [String: Any], dictionary["providerBackupFormat"] as? Int == 1 else {
                throw NSError(domain: "ProfileStore", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Migration backup is invalid"])
            }
            return
        }
        // Publish the defaults and history backup together. A failure leaves the
        // live store untouched and no partial backup to mistake for success.
        let stage = backupDirectory.deletingLastPathComponent()
            .appendingPathComponent(".provider-backup-\(UUID().uuidString)")
        try manager.createDirectory(at: stage, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        // Production rollback must contain the app domain, without importing
        // inherited macOS/global defaults into it. Synthetic suites use their
        // injected representation and never read the production domain.
        var snapshot: [String: Any]
        if defaults === UserDefaults.standard, let domain = Bundle.main.bundleIdentifier {
            snapshot = defaults.persistentDomain(forName: domain) ?? [:]
        } else {
            snapshot = defaults.dictionaryRepresentation()
        }
        snapshot["providerBackupFormat"] = 1
        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        let stagedDefaults = stage.appendingPathComponent(filename)
        try data.write(to: stagedDefaults, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedDefaults.path)
        guard try Data(contentsOf: stagedDefaults) == data else {
            throw NSError(domain: "ProfileStore", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Migration backup verification failed"])
        }
        if manager.fileExists(atPath: historyDirectory.path) {
            let destination = stage.appendingPathComponent("history")
            try manager.createDirectory(at: destination, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            for source in try manager.contentsOfDirectory(at: historyDirectory,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                guard source.pathExtension == "json",
                      try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let contents = try Data(contentsOf: source)
                let copy = destination.appendingPathComponent(source.lastPathComponent)
                try contents.write(to: copy, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                guard try Data(contentsOf: copy) == contents else {
                    throw NSError(domain: "ProfileStore", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "History backup verification failed"])
                }
            }
        }
        try manager.moveItem(at: stage, to: backupDirectory)
    }

    func loadProfiles() -> [Profile] {
        hasUnreadableProfiles = false
        guard let data = defaults.data(forKey: Keys.profiles) else { loadedData = nil; originalRecords = [:]; originalProfiles = [:]; return [] }
        do {
            var profiles = try JSONDecoder().decode([Profile].self, from: data)
            guard Set(profiles.map(\.id)).count == profiles.count else {
                throw NSError(domain: "ProfileStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Duplicate profile identifiers"])
            }
            loadedData = data
            let records = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            originalRecords = Dictionary(uniqueKeysWithValues: zip(profiles.map(\.id), records))
            let fields: [(WritableKeyPath<Profile, String?>, KeychainService.ProfileSecretField)] = [
                (\.claudeSessionKey, .claudeSessionKey), (\.apiSessionKey, .apiSessionKey),
                (\.cliCredentialsJSON, .cliCredentialsJSON), (\.codexCredentialsJSON, .codexCredentialsJSON),
                (\.zaiAPIKey, .zaiAPIKey)
            ]
            var hadPlaintext = false
            for index in profiles.indices {
                for (keyPath, field) in fields {
                    if profiles[index][keyPath: keyPath] != nil { hadPlaintext = true }
                    else { profiles[index][keyPath: keyPath] = keychainService.loadProfileSecret(profileId: profiles[index].id, field: field) }
                }
                if profiles[index].provider == .codex,
                   let details = profiles[index].codexUsage, let config = profiles[index].codexConfiguration,
                   profiles[index].claudeUsage == nil {
                    profiles[index].claudeUsage = details.sharedUsage(configuration: config)
                }
                if profiles[index].provider == .zai,
                   let details = profiles[index].zaiUsage, profiles[index].claudeUsage == nil {
                    profiles[index].claudeUsage = details.sharedUsage(configuration: profiles[index].zaiConfiguration)
                }
            }
            originalProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            if hadPlaintext || !defaults.bool(forKey: "providerCompatibility_v1") {
                _ = saveProfiles(profiles)
            }
            return profiles
        } catch {
            hasUnreadableProfiles = true
            lastPersistenceError = error.localizedDescription
            LoggingService.shared.logStorageError("loadProfiles (original data retained)", error: error)
            return []
        }
    }

    /// Writes a profile's credential fields to the Keychain (nil deletes the item so a
    /// signed-out credential can't be resurrected). Returns false if any write failed.
    /// Every non-nil write is READ BACK and byte-compared before we trust it — the
    /// plist copy is only ever scrubbed for values proven to be retrievable.
    private func persistSecrets(of profile: Profile) throws -> Bool {
        var ok = true
        ok = try persistSecret(profile.claudeSessionKey, profile.id, .claudeSessionKey) && ok
        ok = try persistSecret(profile.apiSessionKey, profile.id, .apiSessionKey) && ok
        ok = try persistSecret(profile.cliCredentialsJSON, profile.id, .cliCredentialsJSON) && ok
        ok = try persistSecret(profile.codexCredentialsJSON, profile.id, .codexCredentialsJSON) && ok
        ok = try persistSecret(profile.zaiAPIKey, profile.id, .zaiAPIKey) && ok
        return ok
    }

    private func persistSecret(_ value: String?, _ profileId: UUID, _ field: KeychainService.ProfileSecretField) throws -> Bool {
        let previous = originalProfiles[profileId]
        let old: String?
        switch field {
        case .claudeSessionKey: old = previous?.claudeSessionKey
        case .apiSessionKey: old = previous?.apiSessionKey
        case .cliCredentialsJSON: old = previous?.cliCredentialsJSON
        case .codexCredentialsJSON: old = previous?.codexCredentialsJSON
        case .zaiAPIKey: old = previous?.zaiAPIKey
        }

        // A missing hydration may mean denied Keychain access. It must never
        // authorize deletion; only an explicit non-nil -> nil edit does that.
        if value == nil, old == nil { return true }
        if let value, keychainService.verifyProfileSecret(value, profileId: profileId, field: field) {
            return true
        }
        guard keychainService.saveProfileSecret(value, profileId: profileId, field: field) else {
            if value == nil, old != nil { throw credentialDeletionFailure(field) }
            return false
        }
        guard let value else {
            guard keychainService.loadProfileSecret(profileId: profileId, field: field) == nil else {
                throw credentialDeletionFailure(field)
            }
            return true
        }
        return keychainService.verifyProfileSecret(value, profileId: profileId, field: field)
    }

    private func credentialDeletionFailure(_ field: KeychainService.ProfileSecretField) -> NSError {
        NSError(domain: "ProfileStore", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not remove saved credential (\(field.rawValue)). The account change was not saved."])
    }

    /// Removes a deleted profile's Keychain items.
    func deleteProfileSecrets(_ profileId: UUID) {
        keychainService.deleteAllProfileSecrets(profileId: profileId)
    }

    func saveActiveProfileId(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Keys.activeProfileId)
    }

    func loadActiveProfileId() -> UUID? {
        guard let uuidString = defaults.string(forKey: Keys.activeProfileId) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    func saveDisplayMode(_ mode: ProfileDisplayMode) {
        defaults.set(mode.rawValue, forKey: Keys.displayMode)
    }

    func loadDisplayMode() -> ProfileDisplayMode {
        guard let rawValue = defaults.string(forKey: Keys.displayMode),
              let mode = ProfileDisplayMode(rawValue: rawValue) else {
            return .single
        }
        return mode
    }

    // MARK: - Multi-Profile Display Config

    func saveMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Keys.multiProfileConfig)
        } catch {
            LoggingService.shared.logStorageError("saveMultiProfileConfig", error: error)
        }
    }

    func loadMultiProfileConfig() -> MultiProfileDisplayConfig {
        guard let data = defaults.data(forKey: Keys.multiProfileConfig) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: data)
        } catch {
            LoggingService.shared.logStorageError("loadMultiProfileConfig", error: error)
            return .default
        }
    }

    // MARK: - Credential Helpers

    func saveProfileCredentials(_ profileId: UUID, credentials: ProfileCredentials) throws {
        var profiles = loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Update credentials directly in profile
        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON

        guard saveProfiles(profiles) else {
            throw NSError(domain: "ProfileStore", code: 4,
                userInfo: [NSLocalizedDescriptionKey: lastPersistenceError ?? "Accounts could not be saved"])
        }
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        return ProfileCredentials(
            claudeSessionKey: profile.claudeSessionKey,
            organizationId: profile.organizationId,
            apiSessionKey: profile.apiSessionKey,
            apiOrganizationId: profile.apiOrganizationId,
            cliCredentialsJSON: profile.cliCredentialsJSON
        )
    }
}
