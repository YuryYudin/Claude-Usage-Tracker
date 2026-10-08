import XCTest
@testable import Claude_Usage

@MainActor
final class ProfilePersistenceRegressionTests: XCTestCase {
    private func fixture(_ run: (UserDefaults, ProfileStore, MemoryProfileSecretStore, ProfileManager) throws -> Void) throws {
        let suite = "profile-manager-regression-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let secrets = MemoryProfileSecretStore()
        let store = ProfileStore(defaults: defaults, secrets: secrets, backupDirectory: directory)
        let first = Profile(name: "A", provider: .zai, zaiAPIKey: "synthetic-a")
        let second = Profile(name: "B", provider: .zai, zaiAPIKey: "synthetic-b")
        XCTAssertTrue(store.saveProfiles([first, second]))
        let manager = ProfileManager(store: store)
        manager.loadProfiles()
        try run(defaults, store, secrets, manager)
    }

    func testRejectedEditRetainsCurrentProfileAndReportsStorageFailure() throws {
        try fixture { defaults, _, _, manager in
            let original = try XCTUnwrap(manager.activeProfile)
            let external = try JSONEncoder().encode([Profile(name: "External")])
            defaults.set(external, forKey: "profiles_v3")
            var edited = original; edited.zaiAPIKey = "must-not-replace"
            XCTAssertFalse(manager.updateProfile(edited))
            XCTAssertEqual(manager.activeProfile, original)
            XCTAssertEqual(manager.profiles.first, original)
            XCTAssertNotNil(manager.storageError)
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), external)
        }
    }

    func testRejectedDeletionNeverRemovesAccountSecrets() throws {
        try fixture { defaults, _, secrets, manager in
            let original = manager.profiles[0]
            let external = try JSONEncoder().encode([Profile(name: "External")])
            defaults.set(external, forKey: "profiles_v3")
            XCTAssertThrowsError(try manager.deleteProfile(original.id))
            XCTAssertEqual(secrets.loadProfileSecret(profileId: original.id, field: .zaiAPIKey), "synthetic-a")
            XCTAssertEqual(manager.profiles.count, 2)
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), external)
        }
    }

    func testRejectedCreationNeverAddsAnUnpersistedAccount() throws {
        try fixture { defaults, _, _, manager in
            let external = try JSONEncoder().encode([Profile(name: "External")])
            defaults.set(external, forKey: "profiles_v3")
            _ = manager.createProfile(name: "Rejected", provider: .zai)
            XCTAssertEqual(manager.profiles.map(\.name), ["A", "B"])
            XCTAssertNotNil(manager.storageError)
        }
    }

    func testEarlyAppWideCodexSettingsMigrateOnceWithCachedTimestamp() throws {
        try fixture { defaults, _, _, manager in
            var settings = CodexSettings()
            settings.monitoringEnabled = true
            settings.executablePath = "/synthetic/codex"
            settings.selectedRateLimitID = "named"
            settings.menuBarMetric.iconStyle = .compact
            let time = Date(timeIntervalSince1970: 1_700_000_000)
            let cached = CodexUsage(account: nil, rateLimits: [], tokenUsage: nil, lastUpdated: time)
            defaults.set(try JSONEncoder().encode(settings), forKey: "codexSettings")
            defaults.set(try JSONEncoder().encode(cached), forKey: "codexUsageData")
            manager.loadProfiles()
            let codex = try XCTUnwrap(manager.profiles.first { $0.provider == .codex })
            XCTAssertEqual(codex.codexConfiguration?.executablePath, "/synthetic/codex")
            XCTAssertEqual(codex.codexConfiguration?.selectedRateLimitID, "named")
            XCTAssertEqual(codex.iconConfig.config(for: .session)?.iconStyle, .compact)
            XCTAssertEqual(codex.claudeUsage?.lastUpdated, time)
            XCTAssertTrue(defaults.bool(forKey: "codexProfileMigrationCompleted"))
            manager.loadProfiles()
            XCTAssertEqual(manager.profiles.filter { $0.provider == .codex }.map(\.id), [codex.id])
        }
    }

    func testClaudeCredentialPatchPreservesOtherFieldsAndRejectsChangedSource() {
        let expected = Profile(name: "A", cliCredentialsJSON: "original", customKeychainServiceName: "source-a")
        var current = expected
        current.name = "Renamed"
        current.refreshInterval = 90
        XCTAssertTrue(CredentialRefreshGuard.canUpdateClaude(current, expected: expected, replacement: "rotated"))
        current.cliCredentialsJSON = "rotated"
        XCTAssertTrue(CredentialRefreshGuard.canUpdateClaude(current, expected: expected, replacement: "rotated"))
        current.cliCredentialsJSON = "another-login"
        XCTAssertFalse(CredentialRefreshGuard.canUpdateClaude(current, expected: expected, replacement: "rotated"))
        current = expected; current.customKeychainServiceName = "source-b"
        XCTAssertFalse(CredentialRefreshGuard.canUpdateClaude(current, expected: expected, replacement: "rotated"))
        current = expected; current.provider = .codex
        XCTAssertFalse(CredentialRefreshGuard.canUpdateClaude(current, expected: expected, replacement: "rotated"))
    }
}
