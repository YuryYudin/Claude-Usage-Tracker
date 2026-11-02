import XCTest
@testable import Claude_Usage

@MainActor
final class ProfileIntegrationTests: XCTestCase {
    private func fixture(_ run: (UserDefaults, ProfileStore, MemoryProfileSecretStore, URL) throws -> Void) throws {
        let suite = "profile-integration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let secrets = MemoryProfileSecretStore()
        let store = ProfileStore(defaults: defaults, secrets: secrets, backupDirectory: directory)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try run(defaults, store, secrets, directory)
    }

    func testKimiKeyPersistsAndDeletesWithoutChangingOtherAccounts() throws {
        try fixture { defaults, store, secrets, _ in
            let old = Profile(name: "Existing", provider: .zai, zaiAPIKey: "existing-key")
            let kimi = Profile(name: "Kimi", provider: .kimi, kimiAPIKey: "kimi-secret",
                kimiConfiguration: .init(region: .china, selectedQuotaID: "limit_month_total"))
            XCTAssertTrue(store.saveProfiles([old, kimi]))
            var profiles = store.loadProfiles()
            XCTAssertEqual(profiles, [old, kimi])
            XCTAssertFalse(String(data: defaults.data(forKey: "profiles_v3")!, encoding: .utf8)!.contains("kimi-secret"))
            XCTAssertEqual(secrets.loadProfileSecret(profileId: kimi.id, field: .kimiAPIKey), "kimi-secret")
            profiles[1].kimiAPIKey = nil
            XCTAssertTrue(store.saveProfiles(profiles))
            XCTAssertNil(secrets.loadProfileSecret(profileId: kimi.id, field: .kimiAPIKey))
            XCTAssertEqual(store.loadProfiles()[0], old)
            XCTAssertNil(store.loadProfiles()[1].kimiAPIKey)
        }
    }

    func testKimiAdHocFallbackRetainsKeyAndRejectsFailedDeletion() throws {
        try fixture { defaults, _, _, directory in
            let store = ProfileStore(defaults: defaults, secrets: UnavailableSecrets(), backupDirectory: directory)
            let profile = Profile(name: "Kimi", provider: .kimi, kimiAPIKey: "kimi-secret")
            XCTAssertTrue(store.saveProfiles([profile]))
            var loaded = store.loadProfiles()
            XCTAssertEqual(loaded.first?.kimiAPIKey, "kimi-secret")
            let before = defaults.data(forKey: "profiles_v3")
            loaded[0].kimiAPIKey = nil
            XCTAssertFalse(store.saveProfiles(loaded))
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), before)
        }
    }

    func testForkAccountsPreserveIDsTargetsSettingsAndSecrets() throws {
        try fixture { defaults, store, secrets, directory in
            var icon = MenuBarIconConfiguration.default
            icon.metrics.append(MetricIconConfig(metricType: .codex, isEnabled: true, iconStyle: .compact, order: 4))
            let profile = Profile(name: "Synthetic SSH", provider: .codex,
                codexConfiguration: CodexProfileConfiguration(connectionType: .ssh, executablePath: "/opt/codex",
                    codexHome: "/accounts/a", sshHost: "account-a", selectedRateLimitID: "named"), iconConfig: icon,
                refreshInterval: 75, isSelectedForDisplay: false)
            let zai = Profile(name: "Synthetic GLM", provider: .zai,
                zaiConfiguration: ZAIProfileConfiguration(selectedLimitID: "TOKENS_LIMIT-6"))
            _ = secrets.saveProfileSecret("synthetic-api-key", profileId: zai.id, field: .zaiAPIKey)
            let original = try JSONEncoder().encode([profile, zai])
            defaults.set(original, forKey: "profiles_v3")
            defaults.set(profile.id.uuidString, forKey: "activeProfileId")
            let decoded = store.loadProfiles()
            XCTAssertEqual(decoded.map(\.id), [profile.id, zai.id])
            XCTAssertEqual(decoded[0].codexConfiguration, profile.codexConfiguration)
            XCTAssertEqual(decoded[0].refreshInterval, 75)
            XCTAssertFalse(decoded[0].isSelectedForDisplay)
            XCTAssertEqual(decoded[0].iconConfig.config(for: .session)?.iconStyle, .compact)
            XCTAssertTrue(decoded[0].iconConfig.config(for: .session)?.isEnabled == true)
            XCTAssertEqual(decoded[1].zaiAPIKey, "synthetic-api-key")
            XCTAssertEqual(store.loadActiveProfileId(), profile.id)
            let backup = try Data(contentsOf: directory.appendingPathComponent("before-provider-integration.plist"))
            let dict = try PropertyListSerialization.propertyList(from: backup, format: nil) as! [String: Any]
            XCTAssertEqual(dict["profiles_v3"] as? Data, original)
            XCTAssertFalse(String(data: defaults.data(forKey: "profiles_v3")!, encoding: .utf8)!.contains("synthetic-api-key"))
            XCTAssertEqual(store.loadProfiles().map(\.id), [profile.id, zai.id])
            XCTAssertTrue(defaults.bool(forKey: "providerCompatibility_v1"))
        }
    }

    func testLegacyClaudeAndDisabledMetricsLoadWithoutLosingAppearance() throws {
        var profile = Profile(name: "Synthetic Claude")
        profile.iconConfig.metrics += [.init(metricType: .codex), .init(metricType: .zai)]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        object["provider"] = "claude"
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.provider, .anthropic)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.iconConfig.enabledMetrics, profile.iconConfig.enabledMetrics)
        XCTAssertFalse(decoded.iconConfig.metrics.contains { $0.metricType == .codex || $0.metricType == .zai })
    }

    func testOneMalformedProfileNeverOverwritesTheOriginalArray() throws {
        try fixture { defaults, store, _, _ in
            let original = Data("[{\"id\":\"not-a-uuid\",\"name\":\"broken\"}]".utf8)
            defaults.set(original, forKey: "profiles_v3")
            XCTAssertTrue(store.loadProfiles().isEmpty)
            XCTAssertTrue(store.hasUnreadableProfiles)
            XCTAssertFalse(store.saveProfiles([Profile(name: "replacement")]))
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), original)
        }
    }

    func testUnknownProviderAndUnknownFieldsSurviveSaving() throws {
        try fixture { defaults, store, _, _ in
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Profile(name: "Future"))) as! [String: Any]
            object["provider"] = "future-provider"
            object["futureConnection"] = ["target": "synthetic-target"]
            defaults.set(try JSONSerialization.data(withJSONObject: [object]), forKey: "profiles_v3")
            var profiles = store.loadProfiles()
            XCTAssertEqual(profiles[0].provider, .unsupported("future-provider"))
            XCTAssertFalse(profiles[0].hasUsageCredentials)
            profiles[0].name = "Renamed"
            XCTAssertTrue(store.saveProfiles(profiles))
            let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: "profiles_v3")!) as! [[String: Any]]
            XCTAssertEqual(saved[0]["provider"] as? String, "future-provider")
            XCTAssertEqual(saved[0]["futureConnection"] as? [String: String], ["target": "synthetic-target"])
        }
    }

    func testExternalStoreChangeBlocksStaleSave() throws {
        try fixture { defaults, store, _, _ in
            XCTAssertTrue(store.saveProfiles([Profile(name: "Original")]))
            let loaded = store.loadProfiles()
            let external = try JSONEncoder().encode([Profile(name: "External")])
            defaults.set(external, forKey: "profiles_v3")
            XCTAssertFalse(store.saveProfiles(loaded))
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), external)
        }
    }

    func testBackupFailureLeavesStoreAndSecretsUntouched() throws {
        try fixture { defaults, _, secrets, directory in
            let profile = Profile(name: "Synthetic", zaiAPIKey: "synthetic-secret")
            let encoder = JSONEncoder(); encoder.userInfo[Profile.includeSecretsKey] = true
            let original = try encoder.encode([profile])
            defaults.set(original, forKey: "profiles_v3")
            try Data("obstruction".utf8).write(to: directory)
            let store = ProfileStore(defaults: defaults, secrets: secrets, backupDirectory: directory)
            XCTAssertEqual(store.loadProfiles().count, 1)
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), original)
            XCTAssertNil(secrets.loadProfileSecret(profileId: profile.id, field: .zaiAPIKey))
            XCTAssertFalse(defaults.bool(forKey: "providerCompatibility_v1"))
        }
    }

    func testDuplicateIdentifiersBlockMigration() throws {
        try fixture { defaults, store, _, _ in
            let profile = Profile(name: "Duplicate")
            let original = try JSONEncoder().encode([profile, profile])
            defaults.set(original, forKey: "profiles_v3")
            XCTAssertTrue(store.loadProfiles().isEmpty)
            XCTAssertTrue(store.hasUnreadableProfiles)
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), original)
        }
    }
    func testKeychainFailureRetainsPlaintextAndDoesNotCompleteMigration() throws {
        try fixture { defaults, _, _, directory in
            let profile = Profile(name: "Synthetic", provider: .zai, zaiAPIKey: "synthetic-secret")
            let encoder = JSONEncoder(); encoder.userInfo[Profile.includeSecretsKey] = true
            defaults.set(try encoder.encode([profile]), forKey: "profiles_v3")
            let store = ProfileStore(defaults: defaults, secrets: UnavailableSecrets(), backupDirectory: directory)
            XCTAssertEqual(store.loadProfiles().first?.zaiAPIKey, "synthetic-secret")
            let saved = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
            XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("synthetic-secret"))
            XCTAssertFalse(defaults.bool(forKey: "providerCompatibility_v1"))
            XCTAssertEqual(store.loadProfiles().first?.zaiAPIKey, "synthetic-secret")
        }
    }

    func testUnavailableHydrationNeverDeletesExistingKeychainItems() throws {
        try fixture { defaults, _, _, directory in
            let profile = Profile(name: "Opaque Keychain", provider: .zai)
            defaults.set(try JSONEncoder().encode([profile]), forKey: "profiles_v3")
            let secrets = OpaqueSecrets()
            let store = ProfileStore(defaults: defaults, secrets: secrets, backupDirectory: directory)
            XCTAssertEqual(store.loadProfiles().first?.id, profile.id)
            XCTAssertEqual(secrets.deletionAttempts, 0)
        }
    }

    func testFailedCredentialRemovalCannotResurrectASignedOutKey() throws {
        try fixture { defaults, _, _, directory in
            let original = Profile(name: "Synthetic", provider: .zai, zaiAPIKey: "synthetic-secret")
            let encoder = JSONEncoder(); encoder.userInfo[Profile.includeSecretsKey] = true
            defaults.set(try encoder.encode([original]), forKey: "profiles_v3")
            let store = ProfileStore(defaults: defaults, secrets: UnavailableSecrets(), backupDirectory: directory)
            var profiles = store.loadProfiles()
            let before = defaults.data(forKey: "profiles_v3")
            profiles[0].zaiAPIKey = nil
            XCTAssertFalse(store.saveProfiles(profiles))
            XCTAssertNotNil(store.lastPersistenceError)
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), before)
            XCTAssertEqual(store.loadProfiles().first?.zaiAPIKey, "synthetic-secret")
        }
    }

    func testHistoryBackupIsPrivateAndRepeatMigrationRetainsOriginalBackup() throws {
        try fixture { defaults, _, secrets, directory in
            let history = directory.deletingLastPathComponent().appendingPathComponent("history-fixture-\(UUID())")
            defer { try? FileManager.default.removeItem(at: history) }
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            let filename = "\(UUID().uuidString).json"
            let originalHistory = Data("{\"snapshots\":[]}".utf8)
            try originalHistory.write(to: history.appendingPathComponent(filename))
            let profile = Profile(name: "Original")
            let original = try JSONEncoder().encode([profile])
            defaults.set(original, forKey: "profiles_v3")
            let store = ProfileStore(defaults: defaults, secrets: secrets, backupDirectory: directory, historyDirectory: history)
            var profiles = store.loadProfiles()
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("history/" + filename)), originalHistory)
            let backupFile = directory.appendingPathComponent("before-provider-integration.plist")
            let before = try Data(contentsOf: backupFile)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backupFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            profiles[0].name = "Renamed"
            XCTAssertTrue(store.saveProfiles(profiles))
            XCTAssertEqual(try Data(contentsOf: backupFile), before)
            // Roll back an isolated defaults suite and verify the original UUID/name.
            let backedUp = try PropertyListSerialization.propertyList(from: before, format: nil) as! [String: Any]
            defaults.set(backedUp["profiles_v3"], forKey: "profiles_v3")
            let rolledBack = try JSONDecoder().decode([Profile].self, from: defaults.data(forKey: "profiles_v3")!)
            XCTAssertEqual(rolledBack.first?.id, profile.id)
            XCTAssertEqual(rolledBack.first?.name, "Original")
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), original)
        }
    }

    func testEncodingFailureNeverChangesSecrets() throws {
        try fixture { defaults, store, secrets, _ in
            var profile = Profile(name: "Synthetic", provider: .zai, zaiAPIKey: "must-not-write")
            var usage = ClaudeUsage.empty; usage.sessionPercentage = .nan
            profile.claudeUsage = usage
            XCTAssertFalse(store.saveProfiles([profile]))
            XCTAssertNil(defaults.data(forKey: "profiles_v3"))
            XCTAssertNil(secrets.loadProfileSecret(profileId: profile.id, field: .zaiAPIKey))
        }
    }

    func testMalformedProviderAmongValidAccountsPreservesEntireArray() throws {
        try fixture { defaults, store, _, _ in
            let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Profile(name: "Valid")))
            var malformed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Profile(name: "Malformed"))) as! [String: Any]
            malformed["provider"] = 42
            let original = try JSONSerialization.data(withJSONObject: [valid, malformed])
            defaults.set(original, forKey: "profiles_v3")
            XCTAssertTrue(store.loadProfiles().isEmpty)
            XCTAssertTrue(store.hasUnreadableProfiles)
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), original)
        }
    }

}


private final class UnavailableSecrets: ProfileSecretStore {
    func loadProfileSecret(profileId: UUID, field: KeychainService.ProfileSecretField) -> String? { nil }
    func saveProfileSecret(_ value: String?, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool { false }
    func verifyProfileSecret(_ expected: String, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool { false }
    func deleteAllProfileSecrets(profileId: UUID) {}
}


private final class OpaqueSecrets: ProfileSecretStore {
    var deletionAttempts = 0
    func loadProfileSecret(profileId: UUID, field: KeychainService.ProfileSecretField) -> String? { nil }
    func saveProfileSecret(_ value: String?, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool {
        if value == nil { deletionAttempts += 1 }
        return false
    }
    func verifyProfileSecret(_ expected: String, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool { false }
    func deleteAllProfileSecrets(profileId: UUID) {}
}
