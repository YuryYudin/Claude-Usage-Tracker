//
//  MigrationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-18.
//

import Foundation

/// Handles data migration from App Group container to standard container
class MigrationService {
    static let shared = MigrationService()

    private init() {}

    private let migrationKey = "HasMigratedFromAppGroup"

    /// Checks if migration has already been completed
    func hasMigrated() -> Bool {
        return UserDefaults.appStorage.bool(forKey: migrationKey)
    }

    /// Checks if we should show the migration option (without triggering TCC dialog)
    /// Returns true if migration hasn't been completed yet (user might have old data)
    func shouldShowMigrationOption() -> Bool {
        // If migration was already completed or declined, don't show
        return !hasMigrated()
    }

    /// Migrates data from App Group container to standard container
    /// - Throws: Error if migration fails
    /// - Returns: Number of keys migrated
    @discardableResult
    func migrateFromAppGroup() throws -> Int {
        LoggingService.shared.log("MigrationService: Starting App Group to standard container migration...")

        // Try to access old App Group UserDefaults
        guard let oldDefaults = UserDefaults(suiteName: Constants.appGroupIdentifier) else {
            LoggingService.shared.log("MigrationService: No App Group data found")
            UserDefaults.appStorage.set(true, forKey: migrationKey)
            return 0
        }

        // Get all keys from old UserDefaults
        let oldData = oldDefaults.dictionaryRepresentation()
        LoggingService.shared.log("MigrationService: Found \(oldData.count) keys to migrate")

        // Copy all data to standard UserDefaults
        for (key, value) in oldData {
            UserDefaults.appStorage.set(value, forKey: key)
        }

        // Synchronize to ensure data is written
        UserDefaults.appStorage.synchronize()

        // Mark migration as complete
        UserDefaults.appStorage.set(true, forKey: migrationKey)

        LoggingService.shared.log("MigrationService: ✅ Successfully migrated \(oldData.count) keys from App Group")

        return oldData.count
    }

    /// Resets all app data (standard container only, NOT old App Group data)
    func resetAppData() {
        LoggingService.shared.log("MigrationService: Resetting app data...")

        // Get all keys from standard UserDefaults
        let allKeys = UserDefaults.appStorage.dictionaryRepresentation().keys

        // Remove all keys
        for key in allKeys {
            UserDefaults.appStorage.removeObject(forKey: key)
        }

        // Synchronize
        UserDefaults.appStorage.synchronize()

        LoggingService.shared.log("MigrationService: ✅ App data reset complete (\(allKeys.count) keys removed)")
    }
}
