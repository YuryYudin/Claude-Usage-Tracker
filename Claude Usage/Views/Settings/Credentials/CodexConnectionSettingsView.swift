import SwiftUI

struct CodexConnectionSettingsView: View {
    @ObservedObject private var profiles = ProfileManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("codex.connection_source".localized, selection: Binding(
                get: { profiles.activeProfile?.codexConfiguration != nil },
                set: { useCLI in
                    guard var profile = profiles.activeProfile else { return }
                    profile.codexConfiguration = useCLI ? CodexProfileConfiguration() : nil
                    profile.claudeUsage = nil
                    profile.codexUsage = nil
                    profiles.updateProfile(profile)
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                }
            )) {
                Text("codex.connection_http".localized).tag(false)
                Text("codex.connection_cli".localized).tag(true)
            }
            .pickerStyle(.segmented).padding()
            if profiles.activeProfile?.codexConfiguration != nil { CodexSettingsView() }
            else { CodexAccountView() }
        }
    }
}
