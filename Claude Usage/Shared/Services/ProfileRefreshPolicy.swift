import Foundation

enum ProfileRefreshPolicy {
    static func inactiveDisplayed(_ profiles: [Profile], activeID: UUID?) -> [Profile] {
        profiles.filter { $0.id != activeID && $0.isSelectedForDisplay && $0.hasAnyCredentials }
    }

    static func autoSwitchCandidate(_ profiles: [Profile], after current: Profile) -> Profile? {
        guard current.provider.descriptor.capabilities.cliAccountSync,
              let index = profiles.firstIndex(where: { $0.id == current.id }), profiles.count > 1 else { return nil }
        for offset in 1..<profiles.count {
            let candidate = profiles[(index + offset) % profiles.count]
            guard candidate.provider == current.provider, candidate.hasUsageCredentials else { continue }
            if candidate.claudeUsage?.effectiveSessionPercentage ?? 0 < 100 { return candidate }
        }
        return nil
    }
}
