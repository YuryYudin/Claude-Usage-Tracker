import Foundation
import UserNotifications
import AppKit

/// Manages user notifications for usage threshold alerts
class NotificationManager: NotificationServiceProtocol {
    static let shared = NotificationManager()

    // Track previous session percentage per profile to detect resets
    private var previousSessionPercentages: [String: Double] = [:]

    // Track which notifications have been sent to prevent duplicates
    // Persisted to UserDefaults to survive app restarts
    private var sentNotifications: Set<String> {
        get {
            Set(UserDefaults.appStorage.array(forKey: "sentNotifications") as? [String] ?? [])
        }
        set {
            UserDefaults.appStorage.set(Array(newValue), forKey: "sentNotifications")
        }
    }

    private init() {}

    /// Names are presentation only; quota/reset identity controls deduplication.
    func checkAndNotify(usage: ClaudeUsage, profileID: UUID, profileName: String,
                        settings: NotificationSettings) {
        guard settings.enabled else { return }
        if usage.quotaWindows == nil, usage.sessionAvailable != false {
            checkSessionNotifications(usage: usage, profileName: profileName,
                identity: profileID.uuidString, settings: settings)
            return
        }
        let quota = usage.primaryQuota
        guard quota != nil || usage.sessionAvailable != false else { return }
        let percentage = quota?.effectivePercentage ?? usage.effectiveSessionPercentage
        let reset = quota?.resetTime ?? (quota == nil ? usage.sessionResetTime : nil)
        let base = "quota_\(profileID)_\(quota?.id ?? "session")_"
        if percentage == 0, (previousSessionPercentages[base] ?? 0) > 0 {
            sentNotifications = sentNotifications.filter { !$0.hasPrefix(base) }
        }
        previousSessionPercentages[base] = percentage
        guard let threshold = settings.sortedThresholds.reversed().first(where: { percentage >= Double($0) }) else { return }
        let window = reset.map { String(Int64($0.timeIntervalSince1970)) } ?? "unknown"
        let prefix = "\(base)\(window)_"
        let identifier = "\(prefix)\(threshold)"
        guard !sentNotifications.contains(identifier) else { return }
        var sent = sentNotifications.filter { !$0.hasPrefix(base) || $0.hasPrefix(prefix) }
        sent.insert(identifier)
        sentNotifications = sent
        let content = UNMutableNotificationContent()
        content.title = "\(profileName) — \(Int(percentage.rounded()))%"
        content.body = quota?.label ?? "menubar.session_usage".localized
        if let reset { content.body += " · \(reset.formatted(date: .abbreviated, time: .shortened))" }
        if settings.soundName == "default" { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            Task { @MainActor in
                if error != nil {
                    var sent = self.sentNotifications
                    sent.remove(identifier)
                    self.sentNotifications = sent
                } else if settings.soundName != "default", settings.soundName != "none" {
                    NSSound(named: NSSound.Name(settings.soundName))?.play()
                }
            }
        }
    }

    /// Sends a notification when approaching usage limits (legacy method)
    func sendUsageAlert(type: AlertType, percentage: Double, resetTime: Date?) {
        // Check if notifications are enabled in preferences
        guard DataStore.shared.loadNotificationsEnabled() else {
            return
        }

        // Map percentage to threshold level to prevent duplicate notifications
        let thresholdLevel: Int
        if percentage >= 95 {
            thresholdLevel = 95
        } else if percentage >= 90 {
            thresholdLevel = 90
        } else if percentage >= 75 {
            thresholdLevel = 75
        } else {
            return // Below all thresholds
        }

        // Create unique identifier based on threshold level, not actual percentage
        let identifier = "\(type.rawValue)_\(thresholdLevel)"

        // Check if we've already sent this notification
        guard !sentNotifications.contains(identifier) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.message(percentage: percentage, resetTime: resetTime)
        content.sound = .default
        content.categoryIdentifier = "USAGE_ALERT"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error == nil {
                // Mark this notification as sent
                var updated = self?.sentNotifications ?? []
                updated.insert(identifier)
                self?.sentNotifications = updated
            }
        }
    }

    /// Sends a simple notification (for non-usage alerts)
    func sendSimpleAlert(type: AlertType) {
        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.message(percentage: 0, resetTime: nil)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: type.rawValue,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { _ in
            // Notification sent
        }
    }

    /// Sends a brief success notification for user-triggered refreshes
    func sendSuccessNotification() {
        let center = UNUserNotificationCenter.current()

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "notification.usage_updated.title".localized
        content.body = "notification.usage_updated.body".localized
        // Silent notification (no sound)
        content.categoryIdentifier = "SUCCESS_ALERT"

        // Create a trigger to deliver immediately
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        // Create the request with a unique identifier
        let identifier = "usage_refresh_success_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // Add the notification request
        center.add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to show success notification: \(error)")
            }
        }

        // Auto-remove after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// Checks usage and sends appropriate alerts (profile-aware)
    func checkAndNotify(usage: ClaudeUsage, profileName: String, settings: NotificationSettings) {
        checkSessionNotifications(usage: usage, profileName: profileName, identity: profileName, settings: settings)
    }

    private func checkSessionNotifications(usage: ClaudeUsage, profileName: String,
                                           identity: String, settings: NotificationSettings) {
        // Check if notifications are enabled for this profile
        guard settings.enabled else {
            return
        }

        let sessionPercentage = usage.effectiveSessionPercentage
        let previousPercentage = previousSessionPercentages[identity] ?? 0.0

        // Check for session reset (went from >0% to 0%)
        if previousPercentage > 0.0 && sessionPercentage == 0.0 {
            // Clear all sent notifications for this profile to allow re-notification in new session
            sentNotifications = sentNotifications.filter { !$0.hasPrefix(identity + "_") }

            sendProfileAlert(
                profileName: profileName, notificationKey: identity,
                type: .sessionReset,
                percentage: sessionPercentage,
                resetTime: usage.sessionResetTime,
                soundName: settings.soundName
            )

            // Note: Auto-start session is handled per-profile but called from elsewhere
        }

        // Update previous percentage for this specific profile
        previousSessionPercentages[identity] = sessionPercentage

        // Check thresholds (highest first) - includes both built-in and custom
        let thresholds = settings.sortedThresholds
        for threshold in thresholds.reversed() {
            if sessionPercentage >= Double(threshold) {
                let alertType: AlertType
                switch threshold {
                case 95...:
                    alertType = .sessionCritical
                case 90..<95:
                    alertType = .sessionWarning
                default:
                    alertType = .sessionInfo
                }
                sendProfileAlert(
                    profileName: profileName, notificationKey: identity,
                    type: alertType,
                    percentage: sessionPercentage,
                    thresholdLevel: threshold,
                    resetTime: usage.sessionResetTime,
                    soundName: settings.soundName
                )
                break
            }
        }
    }

    /// Checks usage and sends appropriate alerts (legacy, for backwards compatibility)
    func checkAndNotify(usage: ClaudeUsage) {
        // Fallback to old behavior if called without profile
        guard DataStore.shared.loadNotificationsEnabled() else {
            return
        }

        let settings = NotificationSettings(
            enabled: true,
            threshold75Enabled: true,
            threshold90Enabled: true,
            threshold95Enabled: true
        )

        checkAndNotify(usage: usage, profileName: "Default", settings: settings)
    }

    /// Sends a profile-specific usage alert
    private func sendProfileAlert(profileName: String, notificationKey: String? = nil, type: AlertType, percentage: Double, thresholdLevel: Int? = nil, resetTime: Date?, soundName: String = "default") {
        // Use the configured threshold level (not current percentage) to prevent duplicate notifications
        let level = thresholdLevel ?? Int(percentage)

        // Create unique identifier based on alert type and threshold level
        let identifier = "\(notificationKey ?? profileName)_\(type.rawValue)_\(level)"

        // Check if we've already sent this notification
        guard !sentNotifications.contains(identifier) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(profileName) - \(type.title)"
        content.body = type.message(percentage: percentage, resetTime: resetTime)
        content.categoryIdentifier = "USAGE_ALERT"

        // Apply sound setting
        // Note: UNNotificationSound(named:) only finds sounds bundled in the app,
        // not system sounds from /System/Library/Sounds/. For custom system sounds,
        // we play via NSSound after the notification is delivered.
        let customSoundName: String? = {
            switch soundName {
            case "none":
                return nil
            case "default":
                content.sound = .default
                return nil
            default:
                return soundName
            }
        }()

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error == nil {
                // Play custom system sound after notification is delivered
                if let name = customSoundName {
                    DispatchQueue.main.async {
                        if let sound = NSSound(named: NSSound.Name(name)) {
                            sound.play()
                        } else {
                            NSSound.beep()
                        }
                    }
                }

                // Mark this notification as sent
                var updated = self?.sentNotifications ?? []
                updated.insert(identifier)
                self?.sentNotifications = updated
            }
        }
    }

    /// Sends auto-start session notification
    func sendAutoStartNotification(profileName: String, success: Bool, error: String?, settings: NotificationSettings) {
        // Check if notifications are enabled for this profile
        guard settings.enabled else {
            return
        }

        let content = UNMutableNotificationContent()

        if success {
            content.title = "\(profileName) - \(AlertType.sessionAutoStarted.title)"
            content.body = AlertType.sessionAutoStarted.message(percentage: 0, resetTime: nil)
            content.sound = .default
            content.categoryIdentifier = "INFO_ALERT"
        } else {
            content.title = "\(profileName) - \(AlertType.sessionAutoStartFailed.title)"
            var message = AlertType.sessionAutoStartFailed.message(percentage: 0, resetTime: nil)
            if let error = error {
                message += " Error: \(error)"
            }
            content.body = message
            content.sound = .default
            content.categoryIdentifier = "ERROR_ALERT"
        }

        let identifier = success ? "auto_start_\(profileName)_success" : "auto_start_\(profileName)_failed_\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send auto-start notification: \(error)")
            }
        }
    }

    /// Sends a notification when auto-switching profiles due to session limit
    ///
    /// - Parameter settings: Notification settings of the profile being switched away from,
    ///   i.e. the one whose session hit the limit and triggered the switch.
    func sendAutoSwitchNotification(fromProfile: String, toProfile: String, settings: NotificationSettings) {
        // Check if notifications are enabled for this profile
        guard settings.enabled else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "notification.profile_auto_switched.title".localized
        content.body = "notification.profile_auto_switched.message".localized(with: fromProfile, toProfile)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let identifier = "auto_switch_\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send auto-switch notification: \(error)")
            }
        }
    }

    /// Clears notification tracking state for a specific profile
    func clearNotificationsForProfile(_ profileName: String) {
        sentNotifications = sentNotifications.filter { !$0.hasPrefix(profileName) }
        previousSessionPercentages.removeValue(forKey: profileName)
    }

    /// Schedules a notification 24 hours before the session key expires
    func scheduleSessionKeyExpiryNotification(expiryDate: Date) {
        let center = UNUserNotificationCenter.current()
        let identifier = "api_session_key_expiry"

        // Remove any existing expiry notification
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        // Schedule 24 hours before expiry
        let triggerDate = expiryDate.addingTimeInterval(-24 * 60 * 60)
        guard triggerDate > Date() else {
            // Already within 24 hours of expiry — send immediately
            sendSimpleAlert(type: .sessionKeyExpiring)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = AlertType.sessionKeyExpiring.title
        content.body = AlertType.sessionKeyExpiring.message(percentage: 0, resetTime: expiryDate)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to schedule session key expiry notification: \(error)")
            }
        }
    }

    /// Clears all pending notifications
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

// MARK: - Alert Types

extension NotificationManager {
    enum AlertType: String {
        case sessionInfo = "session_info"  // 75% threshold
        case sessionWarning = "session_warning"  // 90% threshold
        case sessionCritical = "session_critical"  // 95% threshold
        case sessionReset = "session_reset"
        case sessionAutoStarted = "session_auto_started"
        case sessionAutoStartFailed = "session_auto_start_failed"
        case weeklyWarning = "weekly_warning"
        case weeklyCritical = "weekly_critical"
        case opusWarning = "opus_warning"
        case opusCritical = "opus_critical"
        case sessionKeyExpiring = "session_key_expiring"
        case notificationsEnabled = "notifications_enabled"

        var title: String {
            switch self {
            case .sessionInfo:
                return "Usage Info"
            case .sessionWarning:
                return "notification.session_warning.title".localized
            case .sessionCritical:
                return "notification.session_critical.title".localized
            case .sessionReset:
                return "notification.session_reset.title".localized
            case .sessionAutoStarted:
                return "notification.session_auto_started.title".localized
            case .sessionAutoStartFailed:
                return "notification.session_auto_start_failed.title".localized
            case .weeklyWarning:
                return "notification.weekly_warning.title".localized
            case .weeklyCritical:
                return "notification.weekly_critical.title".localized
            case .opusWarning:
                return "notification.opus_warning.title".localized
            case .opusCritical:
                return "notification.opus_critical.title".localized
            case .sessionKeyExpiring:
                return "API Session Expiring"
            case .notificationsEnabled:
                return "notification.enabled.title".localized
            }
        }

        func message(percentage: Double, resetTime: Date?) -> String {
            let percentStr = String(format: "%.1f%%", percentage)
            let resetStr = resetTime.map { "Resets \(FormatterHelper.timeUntilReset(from: $0))" } ?? ""

            switch self {
            case .sessionInfo:
                return "You've used \(percentStr) of your session limit. \(resetStr)"
            case .sessionWarning:
                return "notification.session_warning.message".localized(with: percentStr, resetStr)
            case .sessionCritical:
                return "notification.session_critical.message".localized(with: percentStr, resetStr)
            case .sessionReset:
                return "notification.session_reset.message".localized
            case .sessionAutoStarted:
                return "notification.session_auto_started.message".localized
            case .sessionAutoStartFailed:
                return "notification.session_auto_start_failed.message".localized
            case .weeklyWarning:
                return "notification.weekly_warning.message".localized(with: percentStr, resetStr)
            case .weeklyCritical:
                return "notification.weekly_critical.message".localized(with: percentStr, resetStr)
            case .opusWarning:
                return "notification.opus_warning.message".localized(with: percentStr, resetStr)
            case .opusCritical:
                return "notification.opus_critical.message".localized(with: percentStr, resetStr)
            case .sessionKeyExpiring:
                if let resetTime = resetTime {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .full
                    let relative = formatter.localizedString(for: resetTime, relativeTo: Date())
                    return "Your API session key expires \(relative). Please re-authenticate to avoid interruption."
                }
                return "Your API session key expires soon. Please re-authenticate to avoid interruption."
            case .notificationsEnabled:
                return "notification.enabled.message".localized
            }
        }
    }
}
