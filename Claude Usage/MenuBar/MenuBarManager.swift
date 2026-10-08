import Cocoa
import SwiftUI
import Combine

class MenuBarManager: NSObject, ObservableObject {
    static weak var current: MenuBarManager?
    private let profileRefresh = ProfileRefreshCoordinator()
    private var inactiveRefreshTimer: Timer?
    private var inactiveRefreshRunning = false
    private var refreshEpochs: [UUID: UUID] = [:]
    @Published private(set) var providerStatuses: [Provider: ClaudeStatus] = [:]
    @Published private(set) var providerErrors: [UUID: String] = [:]
    @Published private(set) var providerFailures: [UUID: Int] = [:]
    @Published private(set) var providerCredentialErrors: Set<UUID> = []
    var isCodexRefreshing: Bool { profileManager.activeProfile.map { profileRefresh.isRefreshing($0.id) } ?? false }
    var isZAIRefreshing: Bool { isCodexRefreshing }
    var codexRefreshError: String? { profileManager.activeProfile.flatMap { providerErrors[$0.id] } }
    var zaiRefreshError: String? { codexRefreshError }
    func refreshCodexUsageNow() { refreshUsage() }
    func refreshZAIUsageNow() { refreshUsage() }

    private var statusItem: NSStatusItem?  // Legacy - kept for backwards compatibility
    private var statusBarUIManager: StatusBarUIManager?
    private var refreshTimer: Timer?
    @Published private(set) var usage: ClaudeUsage = .empty
    @Published private(set) var status: ClaudeStatus = .unknown
    @Published private(set) var apiUsage: APIUsage?
    @Published private(set) var isRefreshing: Bool = false

    // Error tracking for stale data / credential banners
    @Published private(set) var hasCredentialError: Bool = false
    @Published private(set) var consecutiveRefreshFailures: Int = 0
    @Published private(set) var lastRefreshError: String? = nil
    @Published private(set) var lastSuccessfulRefreshTime: Date? = nil

    // Multi-profile mode: track which profile's icon was clicked
    @Published private(set) var clickedProfileId: UUID?
    @Published private(set) var clickedProfileUsage: ClaudeUsage?
    @Published private(set) var clickedProfileAPIUsage: APIUsage?

    // Track when refresh was last triggered (for distinguishing user vs auto refresh)
    private var lastRefreshTriggerTime: Date = .distantPast

    // Track last known reset times for history recording
    private var lastKnownSessionResetTime: [UUID: Date] = [:]
    private var lastKnownWeeklyResetTime: [UUID: Date] = [:]
    private var lastKnownAPIResetTime: [UUID: Date] = [:]

    // Track if a reset was just recorded to prevent duplicate periodic snapshots
    private var resetJustRecorded: [UUID: (session: Bool, weekly: Bool)] = [:]

    // Popover for beautiful SwiftUI interface
    private var popover: NSPopover?

    // Event monitor for closing popover on outside click
    private var eventMonitor: Any?

    // Timestamp of the most recent popover close. Used to debounce the
    // status-item click that dismisses the popover: that same click also fires
    // togglePopover, which would otherwise immediately re-show the popover
    // (the "click makes it bounce back instead of closing" race).
    private var lastPopoverCloseDate: Date = .distantPast
    private weak var lastPopoverCloseButton: NSStatusBarButton?

    // Detached window reference (when popover is detached)
    private var detachedWindow: NSWindow?

    // Settings window reference
    private var settingsWindow: NSWindow?

    // GitHub star prompt window reference
    private var githubPromptWindow: NSWindow?

    // Feedback prompt window reference
    private var feedbackWindow: NSWindow?


    // Track which button is currently showing the popover
    private weak var currentPopoverButton: NSStatusBarButton?

    private let apiService = ClaudeAPIService()
    private let statusService = ClaudeStatusService()

    /// Status service for the active profile's provider (Statuspage-compatible
    /// endpoints across providers; falls back to the Anthropic default).
    private var statusServiceForActiveProfile: ClaudeStatusService {
        guard let url = profileManager.activeProfile?.provider.descriptor.statusPageURL else {
            return statusService
        }
        return ClaudeStatusService(statusURL: url)
    }
    private let dataStore = DataStore.shared
    private let networkMonitor = NetworkMonitor.shared
    private let profileManager = ProfileManager.shared
    private let autoStartService = AutoStartSessionService.shared

    // Combine cancellables for profile observation
    private var cancellables = Set<AnyCancellable>()

    // Track if we've handled the first profile switch (to allow returning to initial profile)
    private var hasHandledFirstProfileSwitch = false

    // Track which profiles have already triggered auto-switch (prevents repeated firing)
    private var autoSwitchedProfileIds: Set<UUID> = []

    // Observer for refresh interval changes
    private var refreshIntervalObserver: NSKeyValueObservation?

    // Observer for icon style changes
    private var iconStyleObserver: NSObjectProtocol?

    // Observer for icon configuration changes
    private var iconConfigObserver: NSObjectProtocol?

    // Observer for credential changes (add, remove, update)
    private var credentialsObserver: NSObjectProtocol?

    // Observer for display mode changes (single/multi profile)
    private var displayModeObserver: NSObjectProtocol?

    // Observer for screen/display changes (headless mode support)
    private var screenObserver: NSObjectProtocol?

    // Observer for wake-from-sleep
    private var wakeObserver: NSObjectProtocol?
    private var lastAutoRefreshTime: Date = .distantPast


    private var multiProfileConfigObserver: NSObjectProtocol?

    // MARK: - Image Caching (CPU Optimization)
    private var cachedImage: NSImage?
    private var cachedImageKey: String = ""
    private var updateDebounceTimer: Timer?
    private var cachedIsDarkMode: Bool = false

    func setup() {
        Self.current = self
        inactiveRefreshTimer?.invalidate()
        inactiveRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in manager.refreshInactiveDisplayedProfiles() }
        }
        refreshInactiveDisplayedProfiles()
        for name in [Notification.Name.codexSettingsChanged, .zaiSettingsChanged] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(providerConfigurationChanged), name: name, object: nil)
        }
        // Initialize cached appearance to avoid layout recursion
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self

        // Check if we should use multi-profile mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode - setup with selected profiles
            setupMultiProfileMode()
        } else {
            // Single profile mode - setup with active profile's config
            let config = profileManager.activeProfile?.iconConfig ?? .default
            // Includes system Keychain CLI credentials as a fallback so users who
            // only authenticated via `claude login` still get metrics enabled.
            let hasCredentials = hasAnyAvailableCredentials()

            // If no credentials anywhere, create empty config to show default logo
            let displayConfig: MenuBarIconConfiguration
            if !hasCredentials {
                displayConfig = MenuBarIconConfiguration(
                    colorMode: config.colorMode,
                    singleColorHex: config.singleColorHex,
                    showIconNames: config.showIconNames,
                    metrics: config.metrics.map { metric in
                        var updatedMetric = metric
                        updatedMetric.isEnabled = false
                        return updatedMetric
                    }
                )
            } else {
                displayConfig = config
            }

            statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)
        }

        // Setup popover
        setupPopover()

        // Load saved data from active profile first (provides immediate feedback).
        // Credential check includes system Keychain CLI fallback so users who
        // authenticated only via `claude login` still see usage data.
        if let profile = profileManager.activeProfile {
            if hasAnyAvailableCredentials() {
                // Credentials available - show saved usage data if present
                if let savedUsage = profile.claudeUsage {
                    usage = savedUsage
                }
                if let savedAPIUsage = profile.apiUsage {
                    apiUsage = savedAPIUsage
                }
            } else {
                // No credentials anywhere - clear any old usage data and show default logo
                usage = .empty
                apiUsage = nil
                LoggingService.shared.log("MenuBarManager: No credentials available (profile or system keychain), showing default logo")
            }
            updateAllStatusBarIcons()
        }

        // Start network monitoring - fetch data when network is available
        networkMonitor.onNetworkAvailable = { [weak self] in
            // Only refresh if we haven't refreshed recently (avoid duplicate on startup)
            guard let self = self else { return }

            // Skip only if no credentials exist anywhere (profile or system keychain)
            guard self.hasAnyAvailableCredentials() else {
                LoggingService.shared.log("Skipping network-available refresh (no credentials available)")
                return
            }

            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastRefreshTriggerTime)
            if timeSinceLastRefresh > 2.0 {  // At least 2 seconds since last refresh
                self.refreshUsage()
            } else {
                LoggingService.shared.log("Skipping network-available refresh (too soon after last refresh)")
            }
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (with small delay for launch-at-login scenarios).
        // Includes system Keychain CLI credentials as a fallback.
        if hasAnyAvailableCredentials() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshUsage()
            }
        } else {
            LoggingService.shared.log("Skipping initial refresh (no credentials available)")
        }

        // Start auto-refresh timer with active profile's interval
        startAutoRefresh()

        // Start auto-start session service (5-minute cycle for all profiles)
        autoStartService.start()

        // Observe icon configuration changes
        observeIconConfigChanges()

        // Observe session key updates
        observeCredentialChanges()

        // Observe display mode changes (single/multi profile)
        observeDisplayModeChanges()
        observeMultiProfileConfigChanges()

        // Setup headless mode observer if enabled (for Remote Desktop support)
        setupHeadlessModeObserver()

        // Setup wake-from-sleep observer for auto-refresh
        setupWakeObserver()

        // Setup global keyboard shortcuts
        setupShortcuts()

    }

    private func setupShortcuts() {
        let shortcutManager = ShortcutManager.shared
        shortcutManager.onTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        shortcutManager.onRefresh = { [weak self] in
            self?.refreshUsage()
        }
        shortcutManager.onOpenSettings = { [weak self] in
            self?.preferencesClicked()
        }
        shortcutManager.onNextProfile = { [weak self] in
            self?.switchToNextProfile()
        }
        shortcutManager.startListening()
    }

    func cleanup() {
        inactiveRefreshTimer?.invalidate()
        inactiveRefreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: .codexSettingsChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .zaiSettingsChanged, object: nil)
        ShortcutManager.shared.stopListening()
        refreshTimer?.invalidate()
        refreshTimer = nil
        networkMonitor.stopMonitoring()
        autoStartService.stop()
        cancellables.removeAll()  // Clean up Combine subscriptions
        refreshIntervalObserver?.invalidate()
        refreshIntervalObserver = nil
        if let iconStyleObserver = iconStyleObserver {
            NotificationCenter.default.removeObserver(iconStyleObserver)
            self.iconStyleObserver = nil
        }
        if let iconConfigObserver = iconConfigObserver {
            NotificationCenter.default.removeObserver(iconConfigObserver)
            self.iconConfigObserver = nil
        }
        if let credentialsObserver = credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
            self.credentialsObserver = nil
        }
        if let displayModeObserver = displayModeObserver {
            NotificationCenter.default.removeObserver(displayModeObserver)
            self.displayModeObserver = nil
        }
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let multiProfileConfigObserver = multiProfileConfigObserver {
            NotificationCenter.default.removeObserver(multiProfileConfigObserver)
            self.multiProfileConfigObserver = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        detachedWindow?.close()
        detachedWindow = nil
        statusItem = nil
        CodexAppServerProvider.shared.retainClients(for: [])
        statusBarUIManager?.cleanup()
        statusBarUIManager = nil

        // Clean up history tracking dictionaries to prevent memory leaks
        lastKnownSessionResetTime.removeAll()
        lastKnownWeeklyResetTime.removeAll()
        lastKnownAPIResetTime.removeAll()
        resetJustRecorded.removeAll()
    }

    /// Cleans up tracking data for a specific profile (called when profile is deleted)
    func cleanupProfile(_ profileId: UUID) {
        lastKnownSessionResetTime.removeValue(forKey: profileId)
        lastKnownWeeklyResetTime.removeValue(forKey: profileId)
        lastKnownAPIResetTime.removeValue(forKey: profileId)
        resetJustRecorded.removeValue(forKey: profileId)
        autoSwitchedProfileIds.remove(profileId)
        providerErrors.removeValue(forKey: profileId)
        providerFailures.removeValue(forKey: profileId)
        providerCredentialErrors.remove(profileId)
        refreshEpochs.removeValue(forKey: profileId)
        publishWidgetSnapshot()
    }

    // MARK: - Profile Observation

    private func observeProfileChanges() {
        profileManager.$profiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishWidgetSnapshot() }
            .store(in: &cancellables)

        // Store the initial profile ID to skip only the very first startup update
        let initialProfileId = profileManager.activeProfile?.id

        // Observe active profile changes
        profileManager.$activeProfile
            .removeDuplicates { oldProfile, newProfile in
                // Only trigger if the profile ID actually changed
                let result = oldProfile?.id == newProfile?.id
                if !result {
                    LoggingService.shared.log("MenuBarManager: Profile ID changed from \(oldProfile?.id.uuidString ?? "nil") to \(newProfile?.id.uuidString ?? "nil")")
                }
                return result
            }
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                guard let self = self, let profile = newProfile else { return }

                // Skip ONLY if this is the startup profile AND we haven't switched yet
                if !self.hasHandledFirstProfileSwitch && profile.id == initialProfileId {
                    LoggingService.shared.log("MenuBarManager: Skipping initial startup profile update to: \(profile.name)")
                    self.hasHandledFirstProfileSwitch = true
                    return
                }

                // Mark that we've handled at least one profile switch
                self.hasHandledFirstProfileSwitch = true

                Task { @MainActor in
                    await self.handleProfileSwitch(to: profile)
                }
            }
            .store(in: &cancellables)

        LoggingService.shared.log("MenuBarManager: Observing profile changes (initial: \(initialProfileId?.uuidString ?? "nil"))")
    }

    private func handleProfileSwitch(to profile: Profile) async {
        LoggingService.shared.log("MenuBarManager: Handling profile switch to: \(profile.name)")
        lastRefreshError = providerErrors[profile.id]
        consecutiveRefreshFailures = providerFailures[profile.id] ?? 0
        hasCredentialError = providerCredentialErrors.contains(profile.id)
        lastSuccessfulRefreshTime = profile.claudeUsage?.lastUpdated
        status = providerStatuses[profile.provider] ?? .unknown


        // 1. Load saved data from new profile (for immediate display)
        await MainActor.run {
            if let savedUsage = profile.claudeUsage {
                self.usage = savedUsage
            } else {
                self.usage = .empty
            }

            if let savedAPIUsage = profile.apiUsage {
                self.apiUsage = savedAPIUsage
            } else {
                self.apiUsage = nil
            }
        }

        // 2. Update refresh interval with profile's setting
        restartAutoRefreshWithInterval(profile.refreshInterval)

        // 3. Update menu bar based on current display mode
        // IMPORTANT: In multi-profile mode, we update all icons, not just switch config
        if profileManager.displayMode == .multi {
            // Multi-profile mode - update icons without recreating status items
            updateMultiProfileDisplay()
        } else {
            // Single profile mode - update menu bar configuration
            updateMenuBarDisplay(with: profile.iconConfig)
        }

        // 4. Recreate popover with new profile data
        recreatePopover()

        // 5. Trigger immediate refresh if any credentials are available, including
        // system Keychain CLI fallback used by ClaudeAPIService.
        if hasAnyAvailableCredentials() {
            self.lastRefreshTriggerTime = Date()
            refreshUsage()
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without usage credentials")
        }
    }

    private func recreatePopover() {
        // Close existing popover if open
        if popover?.isShown == true {
            closePopover()
        }

        // Recreate popover with fresh content
        let newPopover = NSPopover()
        newPopover.contentSize = Constants.WindowSizes.popoverSize
        newPopover.behavior = .semitransient
        // Disabled to avoid an infinite layout-recursion crash on macOS 26/27.
        // The hosting controller's sizingOptions/preferredContentSize (PR #200)
        // keep the popover sized to its content; with animation on, each animated
        // resize re-triggers layout (updateAnimatedWindowSize -> setFrame -> layout)
        // and never converges, overflowing the main-thread stack. Disabling only the
        // animation breaks the loop while preserving content sizing/positioning.
        // See Discussion #64.
        newPopover.animates = false
        newPopover.delegate = self
        newPopover.contentViewController = createContentViewController()

        self.popover = newPopover

        LoggingService.shared.log("MenuBarManager: Popover recreated for profile switch")
    }

    private func updateMenuBarDisplay(with config: MenuBarIconConfiguration) {
        // Skip if in multi-profile mode - this method is for single profile mode only
        guard profileManager.displayMode == .single else {
            LoggingService.shared.log("MenuBarManager: Skipping updateMenuBarDisplay (in multi-profile mode)")
            return
        }

        // Keep configuration decisions aligned with the fetch path so users with
        // only system Keychain CLI credentials keep their configured metric items.
        let hasUsageCredentials = hasAnyAvailableCredentials()

        // If no usage credentials, use an empty config (will show default logo)
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            // Create config with no enabled metrics (will trigger default logo)
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.updateConfiguration(
            target: self,
            action: #selector(togglePopover),
            config: displayConfig
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }
    }

    private func restartAutoRefreshWithInterval(_ interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }

        LoggingService.shared.log("Updated refresh interval to \(interval)s")
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient  // Changed to allow detaching
        // Disabled to avoid an infinite layout-recursion crash on macOS 26/27.
        // The hosting controller's sizingOptions/preferredContentSize (PR #200)
        // keep the popover sized to its content; with animation on, each animated
        // resize re-triggers layout (updateAnimatedWindowSize -> setFrame -> layout)
        // and never converges, overflowing the main-thread stack. Disabling only the
        // animation breaks the loop while preserving content sizing/positioning.
        // See Discussion #64.
        popover.animates = false
        popover.delegate = self

        popover.contentViewController = createContentViewController()
        self.popover = popover
    }

    private func createContentViewController() -> NSHostingController<PopoverContentView> {
        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                self?.refreshViewedProfile()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.preferredContentSize = Constants.WindowSizes.popoverSize
        hostingController.sizingOptions = .preferredContentSize
        return hostingController
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Right-click → show context menu instead of toggling the popover
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(for: sender as? NSStatusBarButton)
            return
        }

        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }

        // In multi-profile mode, determine which profile was clicked
        if statusBarUIManager?.isInMultiProfileMode == true,
           let profileId = statusBarUIManager?.profileId(for: button),
           let profile = profileManager.profiles.first(where: { $0.id == profileId }) {
            // Set the clicked profile data
            clickedProfileId = profileId
            clickedProfileUsage = profile.claudeUsage ?? .empty
            clickedProfileAPIUsage = profile.apiUsage
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = profileManager.activeProfile?.id
            clickedProfileUsage = nil  // Will use manager.usage
            clickedProfileAPIUsage = nil  // Will use manager.apiUsage
        }

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            return
        }

        // Otherwise toggle the popover
        if let popover = popover {
            if popover.isShown {
                // Check if clicking the same button or a different one
                if currentPopoverButton === button {
                    // Same button - close the popover
                    closePopover()
                } else {
                    // Different button - close current and show at new position
                    // Use close() instead of performClose() to avoid async race condition
                    // No need to recreate contentViewController — SwiftUI already observes
                    // the @Published profile properties set earlier in this method
                    popover.close()
                    stopMonitoringForOutsideClicks()
                    showPopover(popover, from: button)
                    currentPopoverButton = button
                    startMonitoringForOutsideClicks()
                }
            } else {
                // Popover not shown - show it.
                // Guard against the dismiss/re-open race: if the popover was just
                // closed (e.g. the outside-click monitor handled this same click a
                // moment before the button action fired), treat this click as the
                // dismissing click and don't immediately re-open it. Only for the
                // button the popover was anchored to — a click on a different
                // status item is a deliberate open, not the dismissing click.
                if button === lastPopoverCloseButton,
                   Date().timeIntervalSince(lastPopoverCloseDate) < 0.25 {
                    return
                }
                // Stop any existing monitor first
                stopMonitoringForOutsideClicks()
                // Update content view controller for current profile data
                popover.contentViewController = createContentViewController()
                showPopover(popover, from: button)
                currentPopoverButton = button
                startMonitoringForOutsideClicks()
            }
        }
    }

    /// Shows `popover` anchored to a status bar button and gives its backing window
    /// the Space placement a menu bar popover needs to appear over a full-screen app.
    private func showPopover(_ popover: NSPopover, from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.enableDisplayOnFullScreenSpaces()
            // AppKit hands initial key focus to the first focusable control in
            // the popover, drawing an accent-colored focus ring around the
            // profile-switcher menu. Nothing in the popover needs initial
            // keyboard focus, so drop first responder to the window itself.
            window.makeFirstResponder(nil)
        }
    }

    /// Shows a lightweight context menu (Refresh / Settings / Quit) anchored to the
    /// status bar button that received the right-click.
    private func showContextMenu(for button: NSStatusBarButton?) {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "common.refresh".localized, action: #selector(contextMenuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "common.settings".localized, action: #selector(preferencesClicked), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "common.quit".localized, action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        // Show the menu at the button's location
        if let button = button {
            // Position the menu below the status bar button
            if let window = button.window {
                let buttonRect = button.convert(button.bounds, to: nil)
                let screenRect = window.convertToScreen(buttonRect)
                menu.popUp(positioning: nil, at: NSPoint(x: screenRect.origin.x, y: screenRect.origin.y), in: nil)
            }
        }
    }

    @objc private func contextMenuRefresh() {
        refreshUsage()
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopMonitoringForOutsideClicks()
        lastPopoverCloseButton = currentPopoverButton
        currentPopoverButton = nil
        lastPopoverCloseDate = Date()
    }

    private func startMonitoringForOutsideClicks() {
        // Only monitor when popover is shown (not detached)
        // Stop monitoring if popover gets detached
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  self.detachedWindow == nil else { return }
            self.closePopover()
        }
    }

    private func stopMonitoringForOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closePopoverOrWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
        } else {
            popover?.performClose(nil)
        }
    }

    // MARK: - Status Bar Icon Updates

    /// Updates all enabled status bar icons
    private func updateAllStatusBarIcons() {
        // Check if in multi-profile mode
        if profileManager.displayMode == .multi {
            // Update multi-profile icons using profiles from profileManager
            let config = profileManager.multiProfileConfig
            statusBarUIManager?.updateMultiProfileButtons(
                profiles: profileManager.profiles,
                config: config,
                activeProfileId: profileManager.activeProfile?.id
            )
        } else {
            // Single profile mode - use the standard update
            statusBarUIManager?.updateAllButtons(
                usage: usage.trayUsage,
                apiUsage: apiUsage
            )
        }
    }

    /// Updates a specific metric's status bar icon
    private func updateStatusBarIcon(for metricType: MenuBarMetricType) {
        statusBarUIManager?.updateButton(
            for: metricType,
            usage: usage.trayUsage,
            apiUsage: apiUsage
        )
    }

    // Legacy method kept for backwards compatibility (now uses new system)
    private func updateStatusButton(_ button: NSStatusBarButton, usage: ClaudeUsage) {
        // This method is deprecated but kept for any remaining references
        // The new system handles updates through updateAllStatusBarIcons()
        updateAllStatusBarIcons()
    }

    // MARK: - Icon Style: Battery (Classic)

    private func startAutoRefresh() {
        let interval = profileManager.activeProfile?.refreshInterval ?? 30.0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.lastAutoRefreshTime = Date()
            self?.refreshUsage()
        }
        refreshTimer?.tolerance = interval * 0.1  // 10% tolerance for energy efficiency
        LoggingService.shared.log("Started auto-refresh with interval: \(interval)s")
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Debounce: only refresh if at least 10 seconds since last auto-refresh
            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastAutoRefreshTime)
            guard timeSinceLastRefresh > 10 else {
                LoggingService.shared.log("MenuBarManager: Skipping wake refresh (debounce)")
                return
            }
            LoggingService.shared.log("MenuBarManager: Wake from sleep detected, refreshing after delay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.lastAutoRefreshTime = Date()
                self?.refreshUsage()
            }
        }
    }

    private func restartAutoRefresh() {
        // Invalidate existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Start new timer with updated interval
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        // Observe the same UserDefaults instance that DataStore uses
        refreshIntervalObserver = dataStore.userDefaults.observe(\.refreshInterval, options: [.new]) { [weak self] _, change in
            if let newValue = change.newValue, newValue > 0 {
                DispatchQueue.main.async {
                    self?.restartAutoRefresh()
                }
            }
        }
    }

    private func observeIconStyleChanges() {
        // Observe icon style changes from settings (now consolidated with menuBarIconConfigChanged)
        iconStyleObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Clear cache to force redraw with new style
            self.cachedImageKey = ""
            self.updateAllStatusBarIcons()
        }
    }

    private func observeCredentialChanges() {
        // Observe credential changes (add, remove, or update)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                // Check if active profile has any credentials, including system
                // Keychain CLI fallback.
                guard let profile = self.profileManager.activeProfile, self.hasAnyAvailableCredentials() else {
                    LoggingService.shared.logInfo("Credentials changed but no usage credentials - showing default logo")

                    // Reconfigure menu bar to show default logo
                    let config = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: config)

                    // No refresh will run, so publish directly: this clears
                    // (or trims) the widget snapshot instead of letting stale
                    // usage linger until the widget's stale threshold.
                    WidgetSnapshotService.shared.publish(
                        profiles: self.profileManager.profiles,
                        activeProfileId: self.profileManager.activeProfile?.id
                    )
                    return
                }

                LoggingService.shared.logInfo("Credentials changed - triggering immediate refresh")

                // Reconfigure menu bar to show metrics (in case we were showing default logo)
                let config = profile.iconConfig
                self.updateMenuBarDisplay(with: config)

                // Mark this as user-triggered
                self.lastRefreshTriggerTime = Date()

                self.refreshUsage()
            }
        }
    }

    private func observeIconConfigChanges() {
        // Observe configuration changes (metrics enabled/disabled, order changes, etc.)
        iconConfigObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Reload configuration from active profile (already on main queue)
            Task { @MainActor in
                // Handle differently based on display mode
                if self.profileManager.displayMode == .multi {
                    // Multi-profile mode - update icons without recreating status items
                    self.updateMultiProfileDisplay()
                } else {
                    // Single profile mode
                    let newConfig = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: newConfig)
                }
            }
        }
    }

    private func observeDisplayModeChanges() {
        // Observe display mode changes (single/multi profile)
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleDisplayModeChange()
            }
        }
    }

    private func observeMultiProfileConfigChanges() {
        // Observe multi-profile visual config changes (icon style, toggles, profile selection)
        // Uses incremental update — does NOT destroy/recreate status items
        multiProfileConfigObserver = NotificationCenter.default.addObserver(
            forName: .multiProfileConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.updateMultiProfileDisplay()
            }
        }
    }

    private func handleDisplayModeChange() {
        let displayMode = profileManager.displayMode

        LoggingService.shared.log("MenuBarManager: Display mode changed to \(displayMode.rawValue)")

        if displayMode == .multi {
            // Switch to multi-profile mode
            setupMultiProfileMode()
        } else {
            // Switch back to single profile mode
            setupSingleProfileMode()
        }
    }

    // MARK: - Headless Mode (Remote Desktop Support)

    private func setupHeadlessModeObserver() {
        // Always observe screen changes to support headless Mac setups (Remote Desktop)
        LoggingService.shared.log("MenuBarManager: Setting up screen change observer for headless support")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func handleScreenChange() {
        // Only proceed if we have screens now
        guard !NSScreen.screens.isEmpty else { return }

        // Check if status bar needs retry (button is nil means it failed on headless startup)
        guard let uiManager = statusBarUIManager else { return }

        if !uiManager.hasValidStatusBar {
            LoggingService.shared.log("MenuBarManager: Headless mode - display connected, retrying status bar setup (screens: \(NSScreen.screens.count))")
            setup()
        }
    }

    /// Returns whether the status bar has at least one valid button
    func hasValidStatusBar() -> Bool {
        return statusBarUIManager?.hasValidStatusBar ?? false
    }

    /// Checks if ANY credentials are available for the active profile, including
    /// provider-specific system-level fallbacks (e.g. Anthropic's system Keychain
    /// CLI credentials, mirroring `ClaudeAPIService.getAuthentication()`).
    private func hasAnyAvailableCredentials() -> Bool {
        guard let profile = profileManager.activeProfile else { return false }
        return ProviderRegistry.service(for: profile.provider).hasCredentials(for: profile)
    }

    private func setupMultiProfileMode() {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.setupMultiProfile(
            profiles: selectedProfiles,
            target: self,
            action: #selector(togglePopover)
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusBarUIManager?.updateMultiProfileButtons(profiles: self.profileManager.profiles, config: config, activeProfileId: self.profileManager.activeProfile?.id)
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile mode enabled with \(selectedProfiles.count) profiles, style=\(config.iconStyle.rawValue)")

        // Refresh data for all selected profiles that have credentials
        refreshAllSelectedProfiles()
    }

    /// Incrementally updates multi-profile status items (without destroying/recreating them)
    /// Use this when only icon config changed but the set of profiles may or may not have changed.
    private func updateMultiProfileDisplay() {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.updateMultiProfileConfiguration(
            profiles: selectedProfiles,
            target: self,
            action: #selector(togglePopover)
        )

        // WORKAROUND: Defer icon update to next run loop iteration to avoid race condition
        // where NSStatusBar layout hasn't finalized yet after status item creation.
        // This prevents potential flicker or layout issues during incremental updates.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusBarUIManager?.updateMultiProfileButtons(profiles: self.profileManager.profiles, config: config, activeProfileId: self.profileManager.activeProfile?.id)
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile display updated incrementally with \(selectedProfiles.count) profiles")
    }

    @objc private func providerConfigurationChanged() {
        guard var profile = profileManager.activeProfile else { return }
        if let details = profile.codexUsage, let config = profile.codexConfiguration {
            profile.claudeUsage = details.sharedUsage(configuration: config)
        } else if let details = profile.zaiUsage {
            profile.claudeUsage = details.sharedUsage(configuration: profile.zaiConfiguration)
        }
        profileManager.updateProfile(profile)
        usage = profile.claudeUsage ?? .empty
        WidgetSnapshotService.shared.publish(profiles: profileManager.profiles, activeProfileId: profile.id)
        updateAllStatusBarIcons()
        refreshUsage()
    }

    private func refreshAllSelectedProfiles() {
        let profiles = profileManager.profiles.filter { $0.isSelectedForDisplay && $0.hasAnyCredentials }
        Task {
            for profile in profiles { await refreshProfile(profile) }
            updateAllStatusBarIcons()
            publishWidgetSnapshot()
        }
    }

    private func refreshInactiveDisplayedProfiles() {
        guard profileManager.displayMode == .single, !inactiveRefreshRunning else { return }
        let activeID = profileManager.activeProfile?.id
        let profiles = ProfileRefreshPolicy.inactiveDisplayed(profileManager.profiles, activeID: activeID)
        guard !profiles.isEmpty else { return }
        inactiveRefreshRunning = true
        Task {
            defer { inactiveRefreshRunning = false }
            for profile in profiles { await refreshProfile(profile) }
            publishWidgetSnapshot()
        }
    }

    private func publishWidgetSnapshot() {
        CodexAppServerProvider.shared.retainClients(for: profileManager.profiles)
        WidgetSnapshotService.shared.publish(profiles: profileManager.profiles,
                                             activeProfileId: profileManager.activeProfile?.id)
    }

    private func matches(_ identity: ProfileAccountIdentity) -> Bool {
        guard let profile = profileManager.profiles.first(where: { $0.id == identity.id }) else { return false }
        return ProfileAccountIdentity(profile) == identity
    }

    private func refreshProfile(_ source: Profile) async {
        let identity = ProfileAccountIdentity(source)
        let epoch = UUID()
        refreshEpochs[source.id] = epoch
        func valid() -> Bool { refreshEpochs[source.id] == epoch && matches(identity) }
        let active = profileManager.activeProfile?.id == source.id
        isRefreshing = true
        let outcome = await profileRefresh.refresh(source, active: active, isCurrent: { _ in valid() })
        isRefreshing = profileRefresh.isRefreshing
        switch outcome {
        case .superseded: return
        case .failed(let error):
            providerErrors[source.id] = error.localizedDescription
            providerFailures[source.id, default: 0] += 1
            let code = AppError.wrap(error).code
            if code == .providerAuthExpired || code == .providerCredentialsNotFound
                || code == .apiUnauthorized || code == .sessionKeyExpired || code == .sessionKeyNotFound {
                providerCredentialErrors.insert(source.id)
            } else { providerCredentialErrors.remove(source.id) }
            if profileManager.activeProfile?.id == source.id {
                consecutiveRefreshFailures = providerFailures[source.id] ?? 0
                lastRefreshError = error.localizedDescription
                hasCredentialError = providerCredentialErrors.contains(source.id)
                ErrorRecovery.shared.recordFailure(for: .api)
            }
            publishWidgetSnapshot()
            // Status and console billing can still succeed when usage fails.
        case .updated(let result):
            guard var current = profileManager.profiles.first(where: { $0.id == source.id }), valid() else { return }
            let previous = current.claudeUsage
            result.updateDetails(&current)
            let newUsage = result.projectUsage?(current) ?? result.usage
            current.claudeUsage = newUsage
            guard profileManager.updateProfile(current) else { return }
            let isNewSample = previous?.lastUpdated != newUsage.lastUpdated
            resetJustRecorded[source.id] = (false, false)
            if isNewSample && newUsage.sessionAvailable != false {
                checkAndRecordSessionReset(profileId: source.id, previousUsage: previous, newUsage: newUsage)
                if resetJustRecorded[source.id]?.session != true {
                    UsageHistoryService.shared.recordSessionPeriodic(for: source.id, usage: newUsage, provider: source.provider)
                }
            }
            if isNewSample && newUsage.weeklyAvailable != false {
                checkAndRecordWeeklyReset(profileId: source.id, previousUsage: previous, newUsage: newUsage)
                if resetJustRecorded[source.id]?.weekly != true {
                    UsageHistoryService.shared.recordWeeklyPeriodic(for: source.id, usage: newUsage, provider: source.provider)
                }
            }
            providerErrors.removeValue(forKey: source.id)
            providerFailures.removeValue(forKey: source.id)
            providerCredentialErrors.remove(source.id)
            if isNewSample {
                NotificationManager.shared.checkAndNotify(usage: newUsage, profileID: current.id,
                    profileName: current.name, settings: current.notificationSettings)
            }
            if profileManager.activeProfile?.id == source.id {
                usage = newUsage
                consecutiveRefreshFailures = 0
                lastRefreshError = nil
                hasCredentialError = false
                lastSuccessfulRefreshTime = newUsage.lastUpdated
                ErrorRecovery.shared.recordSuccess(for: .api)
                if current.provider.descriptor.capabilities.cliAccountSync && StatuslineService.shared.isInstalled {
                    StatuslineService.shared.writeUsageCache(usage: newUsage, profileName: current.name)
                }
                checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: current)
            }
            updateAllStatusBarIcons()
            publishWidgetSnapshot()
        }

        // Billing belongs to the captured account, even if the active profile changes.
        if source.provider.descriptor.capabilities.consoleBilling,
           let key = source.apiSessionKey, let org = source.apiOrganizationId {
            do {
                let billing = try await apiService.fetchAPIUsageData(organizationId: org, apiSessionKey: key)
                guard valid() else { return }
                checkAndRecordBillingCycleReset(profileId: source.id, previousUsage: source.apiUsage, newUsage: billing)
                profileManager.saveAPIUsage(billing, for: source.id)
                if profileManager.activeProfile?.id == source.id { apiUsage = billing }
            } catch { LoggingService.shared.logAPIError("profile billing", error: error) }
        }
        if active || providerStatuses[source.provider] == nil {
            do {
                let serviceStatus = try await ProviderRegistry.service(for: source.provider).fetchStatus()
                guard valid(), let serviceStatus else { return }
                providerStatuses[source.provider] = serviceStatus
                if profileManager.activeProfile?.id == source.id { status = serviceStatus }
            } catch { LoggingService.shared.logAPIError("provider status", error: error) }
        }
    }

    private func setupSingleProfileMode() {
        guard let profile = profileManager.activeProfile else { return }

        let hasUsageCredentials = hasAnyAvailableCredentials()
        let config = profile.iconConfig

        // If no usage credentials, create empty config to show default logo
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Single profile mode enabled")
    }

    private func refreshViewedProfile() {
        guard let id = clickedProfileId,
              let profile = profileManager.profiles.first(where: { $0.id == id }) else {
            refreshUsage()
            return
        }
        Task { await refreshProfile(profile) }
    }

    func refreshUsage() {
        if profileManager.displayMode == .multi { refreshAllSelectedProfiles(); return }
        guard let profile = profileManager.activeProfile else { return }
        guard ProviderRegistry.service(for: profile.provider).hasCredentials(for: profile) else {
            publishWidgetSnapshot()
            updateAllStatusBarIcons()
            return
        }
        Task { await refreshProfile(profile) }
    }

    /// Shows a brief success notification for user-triggered refreshes
    private func showSuccessNotification() {
        NotificationManager.shared.sendSuccessNotification()
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Checks if the current profile hit 100% and switches to the next available one
    private func checkAutoSwitchIfNeeded(usage: ClaudeUsage, currentProfile: Profile) {
        guard currentProfile.provider.descriptor.capabilities.cliAccountSync else { return }
        // Guard: feature must be enabled
        guard SharedDataStore.shared.loadAutoSwitchProfileEnabled() else { return }

        // Guard: need more than 1 profile
        let profiles = profileManager.profiles
        guard profiles.count > 1 else { return }

        let profileId = currentProfile.id

        // If usage dropped below 100%, clear the flag (session reset)
        if usage.effectiveSessionPercentage < 100.0 {
            autoSwitchedProfileIds.remove(profileId)
            return
        }

        // Guard: usage must be >= 100%
        guard usage.effectiveSessionPercentage >= 100.0 else { return }

        // Guard: don't re-trigger for this profile
        guard !autoSwitchedProfileIds.contains(profileId) else { return }

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)

        // Find the next available profile
        guard let nextProfile = findNextAvailableProfile(after: currentProfile) else {
            LoggingService.shared.log("AutoSwitch: All profiles at 100% or unavailable, staying on '\(currentProfile.name)'")
            return
        }

        LoggingService.shared.log("AutoSwitch: Switching from '\(currentProfile.name)' to '\(nextProfile.name)'")

        // Activate the next profile
        let fromName = currentProfile.name
        let toName = nextProfile.name
        let notificationSettings = currentProfile.notificationSettings
        Task {
            await profileManager.activateProfile(nextProfile.id)

            await MainActor.run {
                // Send notification
                NotificationManager.shared.sendAutoSwitchNotification(
                    fromProfile: fromName,
                    toProfile: toName,
                    settings: notificationSettings
                )

                // Post notification for UI reactivity
                NotificationCenter.default.post(name: .autoSwitchProfileTriggered, object: nil)
            }
        }
    }

    /// Finds the next profile with available session capacity, wrapping around
    private func findNextAvailableProfile(after currentProfile: Profile) -> Profile? {
        ProfileRefreshPolicy.autoSwitchCandidate(profileManager.profiles, after: currentProfile)
    }

    // MARK: - Reset Detection for History Recording

    /// Normalizes a date to minute precision for comparison (ignores seconds)
    private func normalizeToMinute(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Checks if a session reset occurred and records a snapshot if so
    private func checkAndRecordSessionReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        if let quotas = newUsage.quotaWindows,
           !quotas.contains(where: { $0.role == .session && $0.resetTime != nil }) { return }
        let lastKnown = lastKnownSessionResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.sessionResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownSessionResetTime[profileId] = newResetTime
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Session reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                let provider = profileManager.profiles.first(where: { $0.id == profileId })?.provider ?? .anthropic
                UsageHistoryService.shared.recordSessionReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.sessionResetTime,  // Use original reset time, not normalized
                    provider: provider
                )
            }

            // Mark that session reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.session = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownSessionResetTime[profileId] = newResetTime
    }

    /// Checks if a weekly reset occurred and records a snapshot if so
    private func checkAndRecordWeeklyReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        if let quotas = newUsage.quotaWindows,
           !quotas.contains(where: { $0.role == .weekly && $0.resetTime != nil }) { return }
        let lastKnown = lastKnownWeeklyResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.weeklyResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownWeeklyResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial weekly reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Weekly reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                let provider = profileManager.profiles.first(where: { $0.id == profileId })?.provider ?? .anthropic
                UsageHistoryService.shared.recordWeeklyReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.weeklyResetTime,  // Use original reset time, not normalized
                    provider: provider
                )
            }

            // Mark that weekly reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.weekly = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownWeeklyResetTime[profileId] = newResetTime
    }

    /// Checks if a billing cycle reset occurred and records a snapshot if so
    private func checkAndRecordBillingCycleReset(
        profileId: UUID,
        previousUsage: APIUsage?,
        newUsage: APIUsage
    ) {
        let lastKnown = lastKnownAPIResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.resetsAt)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownAPIResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial API reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Billing cycle reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordBillingCycleReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.resetsAt  // Use original reset time, not normalized
                )
            }
        }

        // Update the last known reset time
        lastKnownAPIResetTime[profileId] = newResetTime
    }

    @objc private func preferencesClicked() {
        // Close the popover or detached window first
        closePopoverOrWindow()

        // If settings window already exists, just bring it to front
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Small delay to ensure smooth transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Temporarily show dock icon for the settings window (like setup wizard)
            NSApp.setActivationPolicy(.regular)

            // Create and show the settings window
            let window = SettingsWindowBuilder.makeWindow(size: Constants.WindowSizes.settingsWindow)
            window.title = "Claude Usage - Settings"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self

            self.settingsWindow = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func switchToNextProfile() {
        let profiles = profileManager.profiles
        guard profiles.count > 1,
              let currentId = profileManager.activeProfile?.id,
              let currentIndex = profiles.firstIndex(where: { $0.id == currentId }) else {
            return
        }

        let nextIndex = (profiles.index(after: currentIndex)) % profiles.count
        let nextProfile = profiles[nextIndex]

        Task {
            await profileManager.activateProfile(nextProfile.id)
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    /// Shows the GitHub star prompt window
    func showGitHubStarPrompt() {
        // If window already exists, just bring it to front
        if let existingWindow = githubPromptWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Temporarily show dock icon for the prompt window
        NSApp.setActivationPolicy(.regular)

        // Create the GitHub star prompt view
        let promptView = GitHubStarPromptView(
            onStar: { [weak self] in
                self?.handleGitHubStarClick()
            },
            onMaybeLater: { [weak self] in
                self?.handleMaybeLaterClick()
            },
            onDontAskAgain: { [weak self] in
                self?.handleDontAskAgainClick()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 300, height: 145))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        // Store reference
        githubPromptWindow = window

        // Mark that we've shown the prompt
        dataStore.saveLastGitHubStarPromptDate(Date())

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleGitHubStarClick() {
        // Open GitHub repository
        if let url = URL(string: Constants.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }

        // Mark as starred
        dataStore.saveHasStarredGitHub(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleMaybeLaterClick() {
        // Just close the window - the prompt will show again after the reminder interval
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleDontAskAgainClick() {
        // Mark to never show again
        dataStore.saveNeverShowGitHubPrompt(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Feedback Prompt

    /// Shows the feedback collection prompt window
    func showFeedbackPrompt() {
        if let existingWindow = feedbackWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let promptView = FeedbackPromptView(
            onSubmit: { [weak self] _, _, _, _ in
                SharedDataStore.shared.saveHasSubmittedFeedback(true)
                // Close after a brief delay to show the thanks state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.closeFeedbackWindow()
                }
            },
            onRemindLater: { [weak self] in
                SharedDataStore.shared.saveLastFeedbackPromptDate(Date())
                self?.closeFeedbackWindow()
            },
            onDontAskAgain: { [weak self] in
                SharedDataStore.shared.saveNeverShowFeedbackPrompt(true)
                self?.closeFeedbackWindow()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 380, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        feedbackWindow = window
        SharedDataStore.shared.saveLastFeedbackPromptDate(Date())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeFeedbackWindow() {
        feedbackWindow?.close()
        feedbackWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - NSPopoverDelegate
extension MenuBarManager: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        // Allow popover to be detached by dragging
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        // Record every close (transient dismiss, outside-click monitor, or
        // explicit close) so togglePopover can debounce the dismissing click
        // and avoid the "click bounces the popover back open" race.
        lastPopoverCloseDate = Date()
        lastPopoverCloseButton = currentPopoverButton
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        // Stop monitoring for outside clicks when detaching
        stopMonitoringForOutsideClicks()

        // Create content view controller sized for a window (not a popover).
        // We don't use createContentViewController() here because its
        // preferredContentSize/sizingOptions (added by PR #200 for popover
        // positioning) conflict with the window's layout constraints.
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in self?.refreshViewedProfile() },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 280, height: 600))
        window.isReleasedWhenClosed = false
        window.level = .floating
        // Allow a torn-off popover to stay on a full-screen app's Space.
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isRestorable = false
        window.delegate = self
        window.backgroundColor = .clear

        // Store reference to the detached window
        detachedWindow = window

        return window
    }
}

// MARK: - StatusBarUIManagerDelegate
extension MenuBarManager: StatusBarUIManagerDelegate {
    func statusBarAppearanceDidChange() {
        // Safe from infinite loops: StatusBarUIManager's observer deduplicates by
        // appearance name, and setButtonImage() only assigns button.image when the
        // rendered TIFF data actually changes — so even if setting button.image
        // triggers effectiveAppearance KVO, the cycle stops immediately.
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cachedImageKey = ""
        updateAllStatusBarIcons()
    }
}

// MARK: - NSWindowDelegate
extension MenuBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                // Hide dock icon again when settings window closes
                NSApp.setActivationPolicy(.accessory)
                settingsWindow = nil
            } else if window == detachedWindow {
                // Clear detached window reference when closed
                detachedWindow = nil
            } else if window == githubPromptWindow {
                // Hide dock icon again when GitHub prompt window closes
                NSApp.setActivationPolicy(.accessory)
                githubPromptWindow = nil
            }
        }
    }
}
