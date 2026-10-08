//
//  ProfileManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Combine

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?
    @Published var displayMode: ProfileDisplayMode = .single
    @Published var multiProfileConfig: MultiProfileDisplayConfig = .default
    @Published var isSwitchingProfile: Bool = false

    @Published private(set) var storageError: String?
    private let profileStore: ProfileStore
    private let cliSyncService: ClaudeCodeSyncService

    private var switchingSemaphore = false

    init(store: ProfileStore? = nil, cliSyncService: ClaudeCodeSyncService? = nil) {
        self.profileStore = store ?? .shared
        self.cliSyncService = cliSyncService ?? .shared
    }

    @discardableResult
    private func persist(_ candidates: [Profile]) -> Bool {
        let success = profileStore.saveProfiles(candidates)
        storageError = profileStore.lastPersistenceError
        return success
    }

    // MARK: - Initialization

    func loadProfiles() {
        profiles = profileStore.loadProfiles()

        storageError = profileStore.lastPersistenceError
        guard !profileStore.hasUnreadableProfiles else { return }
        // Ensure minimum 1 profile
        if profiles.isEmpty {
            let defaultProfile = createDefaultProfile()
            profiles = [defaultProfile]
            persist(profiles)

            // On first launch, try to sync CLI credentials to the new default profile
            syncCLICredentialsToDefaultProfile(defaultProfile.id)
        }

        migrateLegacyCodexProfileIfNeeded()

        // Load active profile
        if let activeId = profileStore.loadActiveProfileId(),
           let profile = profiles.first(where: { $0.id == activeId }) {
            activeProfile = profile
        } else {
            activeProfile = profiles.first
            if let first = profiles.first {
                profileStore.saveActiveProfileId(first.id)
            }
        }

        displayMode = profileStore.loadDisplayMode()
        multiProfileConfig = profileStore.loadMultiProfileConfig()

        LoggingService.shared.log("ProfileManager: Loaded \(profiles.count) profile(s), active: \(activeProfile?.name ?? "none")")
    }

    // MARK: - Profile Operations

    func createProfile(name: String? = nil, provider: Provider = .anthropic, copySettingsFrom: Profile? = nil) -> Profile {
        let usedNames = profiles.map { $0.name }
        let profileName = name ?? FunnyNameGenerator.getRandomName(excluding: usedNames)

        // Copied icon settings may reference displays the new provider can't
        // render (e.g. token counts) — sanitize against its capabilities.
        var iconConfig = copySettingsFrom?.iconConfig ?? .default
        if !provider.descriptor.capabilities.tokenCounts {
            for index in iconConfig.metrics.indices where iconConfig.metrics[index].weekDisplayMode == .tokens {
                iconConfig.metrics[index].weekDisplayMode = .percentage
            }
        }

        let newProfile = Profile(
            id: UUID(),
            name: profileName,
            provider: provider,
            codexConfiguration: provider == .codex ? copySettingsFrom?.codexConfiguration : nil,
            zaiConfiguration: provider == .zai ? (copySettingsFrom?.zaiConfiguration ?? ZAIProfileConfiguration()) : ZAIProfileConfiguration(),
            hasCliAccount: false,
            iconConfig: iconConfig,
            refreshInterval: copySettingsFrom?.refreshInterval ?? 30.0,
            autoStartSessionEnabled: copySettingsFrom?.autoStartSessionEnabled ?? false,
            checkOverageLimitEnabled: copySettingsFrom?.checkOverageLimitEnabled ?? true,
            notificationSettings: copySettingsFrom?.notificationSettings ?? NotificationSettings(),
            isSelectedForDisplay: true
        )

        let candidates = profiles + [newProfile]
        if persist(candidates) { profiles = candidates }

        LoggingService.shared.log("Created new profile: \(newProfile.name)")
        return newProfile
    }

    @discardableResult
    func updateProfile(_ profile: Profile) -> Bool {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            var candidates = profiles
            candidates[index] = profile
            guard persist(candidates) else { return false }
            profiles = candidates

            if activeProfile?.id == profile.id {
                activeProfile = profile

                // Detailed logging for credential state
                LoggingService.shared.log("ProfileManager.updateProfile: Updated ACTIVE profile '\(profile.name)'")
                LoggingService.shared.log("  - claudeSessionKey: \(profile.claudeSessionKey == nil ? "NIL" : "EXISTS (len: \(profile.claudeSessionKey!.count))")")
                LoggingService.shared.log("  - organizationId: \(profile.organizationId == nil ? "NIL" : "EXISTS")")
                LoggingService.shared.log("  - hasClaudeAI: \(profile.hasClaudeAI)")
                LoggingService.shared.log("  - hasAnyCredentials: \(profile.hasAnyCredentials)")
                LoggingService.shared.log("  - claudeUsage: \(profile.claudeUsage == nil ? "NIL" : "EXISTS")")
            } else {
                LoggingService.shared.log("Updated profile: \(profile.name) (not active)")
            }

            return true
        }
        return false
    }

    func deleteProfile(_ id: UUID) throws {
        guard profiles.count > 1 else {
            throw ProfileError.cannotDeleteLastProfile
        }

        let candidates = profiles.filter { $0.id != id }
        guard persist(candidates) else {
            throw NSError(domain: "ProfileStore", code: 4,
                userInfo: [NSLocalizedDescriptionKey: storageError ?? "Accounts could not be saved"])
        }
        let profileName = profiles.first(where: { $0.id == id })?.name ?? "unknown"

        // Remove the profile's terminal launcher script, if any (the launcher's
        // config dir and login are left in place — see TerminalLauncherService).
        if let profile = profiles.first(where: { $0.id == id }) {
            TerminalLauncherService.shared.uninstall(profile)
        }

        // Clean up usage history for this profile
        UsageHistoryService.shared.deleteHistory(for: id)
        LoggingService.shared.log("Successfully deleted usage history for profile: \(profileName)")

        profiles = candidates

        // Remove the profile's credentials from the Keychain (they no longer live
        // in the profiles plist — #267).
        profileStore.deleteProfileSecrets(id)

        // Switch to first profile if deleted active
        if activeProfile?.id == id {
            if let first = profiles.first {
                Task {
                    await activateProfile(first.id)
                }
            }
        }

        LoggingService.shared.log("Deleted profile: \(profileName)")
    }

    func toggleProfileSelection(_ id: UUID) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[index].isSelectedForDisplay.toggle()
                self.persist(self.profiles)
            }
        }
    }

    func getSelectedProfiles() -> [Profile] {
        displayMode == .single
            ? [activeProfile].compactMap { $0 }
            : profiles.filter { $0.isSelectedForDisplay }
    }

    func updateDisplayMode(_ mode: ProfileDisplayMode) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            self?.profileStore.saveDisplayMode(mode)
            LoggingService.shared.log("Updated display mode to: \(mode.rawValue)")
        }
    }

    func updateMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.multiProfileConfig = config
            self?.profileStore.saveMultiProfileConfig(config)
            LoggingService.shared.log("Updated multi-profile config: style=\(config.iconStyle.rawValue), showWeek=\(config.showWeek)")
        }
    }

    // MARK: - Profile Activation (Centralized)

    func activateProfile(_ id: UUID) async {
        guard !switchingSemaphore else {
            LoggingService.shared.log("Profile switch already in progress, ignoring")
            return
        }

        guard let profile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found: \(id)")
            return
        }

        if activeProfile?.id == id {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return
        }

        switchingSemaphore = true
        isSwitchingProfile = true
        defer { switchingSemaphore = false; isSwitchingProfile = false }

        LoggingService.shared.log("Switching to profile: \(profile.name)")

        // Re-sync current profile before leaving (Anthropic-only: providers
        // without CLI account sync never touch the Claude Code keychain)
        if let currentProfile = activeProfile,
           currentProfile.provider.descriptor.capabilities.cliAccountSync,
           currentProfile.cliCredentialsJSON != nil {
            do {
                try cliSyncService.resyncBeforeSwitching(for: currentProfile.id)
                // Reload profiles to get the updated data in memory
                profiles = profileStore.loadProfiles()
                LoggingService.shared.log("✓ Re-synced current profile before switching")
            } catch {
                LoggingService.shared.logError("Failed to re-sync current profile (non-fatal)", error: error)
            }
        }

        // Reload profiles from disk to get latest data (including any resyncs from other profiles)
        profiles = profileStore.loadProfiles()

        // Get the updated target profile from the reloaded data
        guard let updatedProfile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found after reload: \(id)")
            switchingSemaphore = false
            isSwitchingProfile = false
            return
        }

        // Apply new profile's CLI credentials (if available; Anthropic-only —
        // switching to e.g. a Codex profile must not rewrite ~/.claude.json
        // or the Claude Code keychain entry)
        LoggingService.shared.log("Checking CLI credentials for profile '\(updatedProfile.name)': hasJSON=\(updatedProfile.cliCredentialsJSON != nil)")

        if updatedProfile.provider.descriptor.capabilities.cliAccountSync,
           updatedProfile.cliCredentialsJSON != nil {
            // Refresh the OAuth token before applying. Stored tokens expire (~8h),
            // so applying a stale snapshot would write a dead access token to the
            // keychain and Claude Code would 401 ("Please run /login"). This refreshes
            // via the refresh_token grant and persists the rotated tokens back to the
            // profile, so applyProfileCredentials below writes a valid token.
            var refreshedJSON: String?
            if let refreshed = await cliSyncService.ensureFreshCredentials(for: updatedProfile.id, allowRotation: true) {
                refreshedJSON = refreshed
                LoggingService.shared.log("✓ Ensured fresh credentials before apply for: \(updatedProfile.name)")
                _ = refreshed
                // Reload so applyProfileCredentials picks up the refreshed token.
                profiles = profileStore.loadProfiles()
            }
            guard let current = profiles.first(where: { $0.id == id }),
                  current.provider == updatedProfile.provider,
                  current.customKeychainServiceName == updatedProfile.customKeychainServiceName,
                  current.oauthAccountJSON == updatedProfile.oauthAccountJSON,
                  current.cliCredentialsJSON == updatedProfile.cliCredentialsJSON || current.cliCredentialsJSON == refreshedJSON else { return }
            do {
                try cliSyncService.applyProfileCredentials(updatedProfile.id)
                LoggingService.shared.log("✓ Applied CLI credentials for: \(updatedProfile.name)")
            } catch {
                LoggingService.shared.logError("Failed to apply CLI credentials (non-fatal)", error: error)
            }
        } else {
            LoggingService.shared.log("⚠️ Profile '\(updatedProfile.name)' has no CLI credentials JSON")
        }

        // Update last used timestamp
        // Token refresh may have changed this profile while activation awaited it.
        // Always commit the current record, never the pre-refresh snapshot.
        guard var updated = profiles.first(where: { $0.id == id }) else { return }
        updated.lastUsedAt = Date()

        guard updateProfile(updated) else { return }
        activeProfile = updated
        profileStore.saveActiveProfileId(id)

        // Update statusline script if the new profile has credentials
        // (statusline is Claude Code infrastructure — capability-gated)
        if updated.provider.descriptor.capabilities.cliAccountSync,
           updated.claudeSessionKey != nil && updated.organizationId != nil {
            do {
                try StatuslineService.shared.updateScriptsIfInstalled()
                LoggingService.shared.log("✓ Updated statusline for profile: \(updated.name)")
            } catch {
                LoggingService.shared.logError("Failed to update statusline (non-fatal)", error: error)
            }
        }

        // Statusline configuration belongs to Claude Code accounts.
        if updated.provider.descriptor.capabilities.cliAccountSync {
            do {
                try StatuslineService.shared.updateProfileNameInConfig(updated.name)
            } catch {
                LoggingService.shared.logError("Failed to update statusline profile name (non-fatal)", error: error)
            }
        }

        switchingSemaphore = false
        isSwitchingProfile = false

        LoggingService.shared.log("Successfully activated profile: \(updatedProfile.name)")
    }

    // MARK: - Credentials

    func loadCredentials(for profileId: UUID) throws -> ProfileCredentials {
        return try profileStore.loadProfileCredentials(profileId)
    }

    func saveCredentials(for profileId: UUID, credentials: ProfileCredentials) throws {
        guard var current = profiles.first(where: { $0.id == profileId }) else { throw ClaudeCodeError.noProfileCredentials }
        current.claudeSessionKey = credentials.claudeSessionKey
        current.organizationId = credentials.organizationId
        current.apiSessionKey = credentials.apiSessionKey
        current.apiOrganizationId = credentials.apiOrganizationId
        current.cliCredentialsJSON = credentials.cliCredentialsJSON
        guard updateProfile(current) else { throw persistenceFailure() }
    }

    func removeClaudeAICredentials(for profileId: UUID) throws {
        guard var current = profiles.first(where: { $0.id == profileId }) else { throw ClaudeCodeError.noProfileCredentials }
        current.claudeSessionKey = nil; current.organizationId = nil; current.claudeUsage = nil
        guard updateProfile(current) else { throw persistenceFailure() }
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    func removeAPICredentials(for profileId: UUID) throws {
        guard var current = profiles.first(where: { $0.id == profileId }) else { throw ClaudeCodeError.noProfileCredentials }
        current.apiSessionKey = nil; current.apiOrganizationId = nil; current.apiUsage = nil
        guard updateProfile(current) else { throw persistenceFailure() }
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    private func persistenceFailure() -> NSError {
        NSError(domain: "ProfileStore", code: 4,
            userInfo: [NSLocalizedDescriptionKey: storageError ?? "Accounts could not be saved"])
    }

    // MARK: - Usage Data

    /// Saves Claude usage data for a specific profile
    func saveClaudeUsage(_ usage: ClaudeUsage, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.claudeUsage = usage
        updateProfile(profile)
    }

    /// Loads Claude usage data for a specific profile
    func loadClaudeUsage(for profileId: UUID) -> ClaudeUsage? {
        return profiles.first(where: { $0.id == profileId })?.claudeUsage
    }

    /// Saves API usage data for a specific profile
    func saveAPIUsage(_ usage: APIUsage, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.apiUsage = usage
        updateProfile(profile)
    }

    /// Loads API usage data for a specific profile
    func loadAPIUsage(for profileId: UUID) -> APIUsage? {
        return profiles.first(where: { $0.id == profileId })?.apiUsage
    }

    // MARK: - Profile Settings

    /// Updates icon configuration for a profile
    func updateIconConfig(_ config: MenuBarIconConfiguration, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.iconConfig = config
        updateProfile(profile)
    }

    /// Updates refresh interval for a profile
    func updateRefreshInterval(_ interval: TimeInterval, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.refreshInterval = interval
        updateProfile(profile)
    }

    /// Updates auto-start session setting for a profile
    func updateAutoStartSessionEnabled(_ enabled: Bool, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.autoStartSessionEnabled = enabled
        updateProfile(profile)
    }

    /// Updates check overage limit setting for a profile
    func updateCheckOverageLimitEnabled(_ enabled: Bool, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.checkOverageLimitEnabled = enabled
        updateProfile(profile)
    }

    /// Updates notification settings for a profile
    func updateNotificationSettings(_ settings: NotificationSettings, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.notificationSettings = settings
        updateProfile(profile)
    }

    /// Updates organization ID for a profile
    func updateOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.organizationId = orgId
        updateProfile(profile)
    }

    /// Updates API organization ID for a profile
    func updateAPIOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else { return }
        profile.apiOrganizationId = orgId
        updateProfile(profile)
    }

    // MARK: - Private Helpers

    /// Syncs CLI credentials to default profile on first launch only
    private func syncCLICredentialsToDefaultProfile(_ profileId: UUID) {
        do {
            // Attempt to read credentials from system Keychain
            guard let jsonData = try cliSyncService.readSystemCredentials() else {
                LoggingService.shared.log("ProfileManager: No CLI credentials found in system Keychain")
                return
            }

            // Validate: not expired
            if cliSyncService.isTokenExpired(jsonData) {
                LoggingService.shared.log("ProfileManager: CLI credentials found but expired")
                return
            }

            // Validate: has valid access token
            guard cliSyncService.extractAccessToken(from: jsonData) != nil else {
                LoggingService.shared.log("ProfileManager: CLI credentials found but missing access token")
                return
            }

            // Sync to the newly created default profile
            try cliSyncService.syncToProfile(profileId)

            // Reload the profile to get updated credentials
            profiles = profileStore.loadProfiles()

            LoggingService.shared.log("ProfileManager: ✅ Successfully synced CLI credentials to default profile on first launch")

        } catch {
            LoggingService.shared.logError("ProfileManager: Failed to sync CLI credentials on first launch (non-fatal)", error: error)
            // Non-fatal: profile will be created without credentials
            // User can manually sync in settings
        }
    }

    private func migrateLegacyCodexProfileIfNeeded() {
        let defaults = profileStore.preferences
        guard !defaults.bool(forKey: "codexProfileMigrationCompleted") else { return }
        guard !profiles.contains(where: { $0.provider == .codex }),
              let data = defaults.data(forKey: "codexSettings"),
              let settings = try? JSONDecoder().decode(CodexSettings.self, from: data),
              settings.monitoringEnabled else { return }
        let cached = defaults.data(forKey: "codexUsageData").flatMap { try? JSONDecoder().decode(CodexUsage.self, from: $0) }
        guard settings.menuBarMetric.isEnabled || cached != nil else { return }
        var metric = settings.menuBarMetric
        metric.metricType = .session
        let profile = Profile(name: "Codex", provider: .codex,
            codexConfiguration: CodexProfileConfiguration(executablePath: settings.executablePath,
                selectedRateLimitID: settings.selectedRateLimitID, showAccountEmail: settings.showAccountEmail),
            codexUsage: cached, claudeUsage: cached?.sharedUsage(configuration: CodexProfileConfiguration(
                executablePath: settings.executablePath, selectedRateLimitID: settings.selectedRateLimitID)), iconConfig: MenuBarIconConfiguration(metrics: [metric, .weekDefault, .apiDefault]),
            notificationSettings: NotificationSettings(enabled: settings.notificationsEnabled,
                threshold75Enabled: settings.notificationThresholds.contains(75),
                threshold90Enabled: settings.notificationThresholds.contains(90),
                threshold95Enabled: settings.notificationThresholds.contains(95),
                customThresholds: settings.notificationThresholds.filter { ![75, 90, 95].contains($0) }))
        let candidates = profiles + [profile]
        if persist(candidates) {
            profiles = candidates
            defaults.set(true, forKey: "codexProfileMigrationCompleted")
        }
    }

    private func createDefaultProfile() -> Profile {
        Profile(
            name: FunnyNameGenerator.getRandomName(excluding: []),
            iconConfig: .default,
            refreshInterval: 30.0,
            autoStartSessionEnabled: false,
            checkOverageLimitEnabled: true,
            notificationSettings: NotificationSettings()
        )
    }

}

// MARK: - ProfileError

enum ProfileError: LocalizedError {
    case cannotDeleteLastProfile

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastProfile:
            return "Cannot delete the last profile. At least one profile is required."
        }
    }
}
