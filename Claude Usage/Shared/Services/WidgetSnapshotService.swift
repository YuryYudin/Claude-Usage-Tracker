import Foundation
import WidgetKit

/// Publishes the current usage of the display-selected profiles (plus the
/// active profile) to the WidgetKit extension.
///
/// Mirrors `StatuslineService.writeUsageCache`: after each refresh cycle the
/// app serializes a small JSON snapshot to Application Support and asks
/// WidgetKit to reload timelines. Timeline reloads only happen on meaningful
/// changes, but the snapshot itself is rewritten at least every
/// `heartbeatInterval` — the widget uses `generatedAt` as an app-alive
/// signal, so a healthy app with flat usage must still refresh it.
final class WidgetSnapshotService {
    static let shared = WidgetSnapshotService()

    /// Serializes all publish state; `publish` may be called from any thread.
    private let lock = NSLock()
    private var lastPublishedProfiles: [WidgetSnapshot.ProfileEntry]?
    private var lastWriteTime: Date = .distantPast
    private var lastReloadTime: Date = .distantPast
    private var pendingReload: DispatchWorkItem?

    /// Maximum age of the on-disk snapshot while the app is running. Must be
    /// comfortably below the widget's stale threshold (15 min).
    private let heartbeatInterval: TimeInterval

    /// Minimum spacing between WidgetKit reload requests, so frequent
    /// refresh cycles don't exhaust the system's reload budget.
    private let reloadInterval: TimeInterval

    private let now: () -> Date
    private let writeSnapshot: (WidgetSnapshot) throws -> Void
    private let requestReload: () -> Void

    /// Dependency-injecting initializer; production code uses `shared`,
    /// tests substitute the clock, writer, and reload hook.
    init(
        now: @escaping () -> Date = Date.init,
        writeSnapshot: @escaping (WidgetSnapshot) throws -> Void = { try $0.write() },
        requestReload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        heartbeatInterval: TimeInterval = 5 * 60,
        reloadInterval: TimeInterval = 60
    ) {
        self.now = now
        self.writeSnapshot = writeSnapshot
        self.requestReload = requestReload
        self.heartbeatInterval = heartbeatInterval
        self.reloadInterval = reloadInterval
    }

    /// The snapshot file is readable outside the sandbox (the widget reaches
    /// it through a read-only path exception, not an App Group), so profile
    /// names are reduced before persisting: an email-shaped name — the usual
    /// case for credential-derived profiles — keeps only its local part, and
    /// the result is stripped of control characters and length-capped.
    static let maxProfileNameLength = WidgetSnapshot.maximumProfileNameLength

    static func sanitizedProfileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = name.firstIndex(of: "@"),
           at != name.startIndex,
           name[name.index(after: at)...].contains(".") {
            name = String(name[..<at])
        }
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        name = String(String.UnicodeScalarView(scalars))
        return String(name.prefix(maxProfileNameLength))
    }

    /// Builds a snapshot from the given profiles and publishes it if it
    /// differs from the last published one or the heartbeat is due.
    func publish(profiles: [Profile], activeProfileId: UUID?) {
        let date = now()
        var entries: [WidgetSnapshot.ProfileEntry] = profiles.compactMap { profile in
            let active = profile.id == activeProfileId
            guard profile.isSelectedForDisplay || active,
                  profile.hasAnyCredentials, let usage = profile.claudeUsage,
                  usage.primaryQuota != nil || usage.sessionAvailable != false || usage.weeklyAvailable != false else { return nil }
            let provider: WidgetSnapshot.ProfileEntry.Provider
            switch profile.provider {
            case .anthropic: provider = .claude
            case .codex: provider = .codex
            case .zai: provider = .zai
            case .kimi: provider = .kimi
            case .unsupported: return nil
            }
            let primary = usage.primaryQuota
            let primaryIsWeekly = primary?.role == .weekly
                || (primary == nil && usage.sessionAvailable == false)
            let primaryValue = primary?.effectivePercentage(at: date)
                ?? (primaryIsWeekly ? usage.weeklyPercentage : usage.effectiveSessionPercentage)
            let reset = primary?.resetTime ?? (primary == nil
                ? (primaryIsWeekly ? usage.weeklyResetTime : usage.sessionResetTime) : nil)
            let secondaryRole: UsageQuota.Role = primaryIsWeekly ? .session : .weekly
            let secondary = usage.quotaWindows?.first(where: {
                $0.role == secondaryRole && (primary == nil || $0.bucketID == primary?.bucketID)
            }) ?? usage.quotaWindows?.first(where: {
                $0.role == .other && $0.widgetLabelKey != nil && $0.id != primary?.id
                    && (primary == nil || $0.bucketID == primary?.bucketID)
            })
            let secondaryValue: Double? = secondary?.effectivePercentage(at: date)
                ?? (usage.quotaWindows == nil && usage.weeklyAvailable != false && !primaryIsWeekly
                    ? usage.weeklyPercentage : nil)
            let secondaryReset = secondary?.resetTime
                ?? (usage.quotaWindows == nil && secondaryValue != nil ? usage.weeklyResetTime : nil)
            return WidgetSnapshot.ProfileEntry(id: profile.id, name: Self.sanitizedProfileName(profile.name),
                provider: provider, isActive: active, isDisplayed: profile.isSelectedForDisplay,
                sessionPercentage: primaryValue, sessionResetTime: reset,
                weeklyPercentage: secondaryValue, weeklyResetTime: secondaryReset,
                lastUpdated: usage.lastUpdated,
                primaryLabel: primary?.widgetLabelKey ?? (primary?.role == .tools ? "widget.tools" : (primary?.role == .other ? "widget.quota" : (primaryIsWeekly ? "widget.weekly" : "widget.session"))),
                secondaryLabel: secondary?.widgetLabelKey ?? (secondary?.role == .session ? "widget.session" : "widget.weekly"))
        }
        if entries.count > WidgetSnapshot.maximumProfileCount {
            let active = entries.first(where: \.isActive)
            entries = Array(entries.prefix(WidgetSnapshot.maximumProfileCount))
            if let active, !entries.contains(where: { $0.id == active.id }) {
                entries[entries.count - 1] = active
            }
        }
        publish(entries: entries)
    }

    /// An empty entries list is still published: it clears the widget to
    /// its no-data state (e.g. after the last credentials were removed).
    /// Old data must not linger on disk until the stale threshold.
    func publish(entries: [WidgetSnapshot.ProfileEntry]) {
        lock.lock()
        defer { lock.unlock() }

        let changed = hasMeaningfulChange(entries)
        let heartbeatDue = now().timeIntervalSince(lastWriteTime) >= heartbeatInterval
        guard changed || heartbeatDue else { return }

        let snapshot = WidgetSnapshot(generatedAt: now(), profiles: entries)
        do {
            try writeSnapshot(snapshot)
            lastWriteTime = now()
            lastPublishedProfiles = entries
            if changed {
                requestOrDeferReloadLocked()
            }
        } catch {
            LoggingService.shared.log("WidgetSnapshotService: Failed to write snapshot - \(error.localizedDescription)")
        }
    }

    /// Reloads immediately when outside the throttle window; otherwise
    /// schedules a single deferred reload for when the window reopens, so a
    /// throttled change is never silently dropped until the next one.
    /// Must be called with `lock` held.
    private func requestOrDeferReloadLocked() {
        let remaining = reloadInterval - now().timeIntervalSince(lastReloadTime)
        if remaining <= 0 {
            pendingReload?.cancel()
            pendingReload = nil
            lastReloadTime = now()
            requestReload()
        } else if pendingReload == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.pendingReload != nil else { return }
                self.pendingReload = nil
                self.lastReloadTime = self.now()
                self.requestReload()
            }
            pendingReload = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }

    /// Whole-percent or reset-time changes are worth a widget reload;
    /// sub-percent jitter is not.
    private func hasMeaningfulChange(_ entries: [WidgetSnapshot.ProfileEntry]) -> Bool {
        guard let previous = lastPublishedProfiles, previous.count == entries.count else {
            return true
        }
        for (old, new) in zip(previous, entries) {
            let identityChanged = old.id != new.id || old.name != new.name
                || old.isActive != new.isActive || old.isDisplayed != new.isDisplayed
                || old.primaryLabel != new.primaryLabel || old.secondaryLabel != new.secondaryLabel
                || old.isStale(at: now(), interval: 900) != new.isStale(at: now(), interval: 900)
            let providerChanged = old.provider != new.provider
            let sessionChanged = normalizedPercentage(old.sessionPercentage)
                != normalizedPercentage(new.sessionPercentage)
                || normalizedReset(old.sessionResetTime) != normalizedReset(new.sessionResetTime)
            let weeklyChanged = normalizedPercentage(old.weeklyPercentage)
                != normalizedPercentage(new.weeklyPercentage)
                || normalizedReset(old.weeklyResetTime) != normalizedReset(new.weeklyResetTime)
            if identityChanged || providerChanged || sessionChanged || weeklyChanged {
                return true
            }
        }
        return false
    }

    private func normalizedPercentage(_ value: Double?) -> Int? {
        guard let value,
              value.isFinite,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    private func normalizedReset(_ value: Date?) -> Int? {
        guard let seconds = value?.timeIntervalSince1970,
              seconds.isFinite,
              seconds >= Double(Int.min),
              seconds <= Double(Int.max) else { return nil }
        return Int(seconds)
    }
}
