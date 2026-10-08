import SwiftUI

struct ZAISetupView: View {
    var onDone: () -> Void
    var onBack: () -> Void
    @State private var apiKey = ""
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        VStack(spacing: 20) {
            Text("zai.settings.title".localized).font(.title2)
            Text("zai.settings.setup_steps".localized)
            SecureField("zai.settings.api_key".localized, text: $apiKey).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("common.back".localized, action: onBack).disabled(testing)
                Button("codex.test_connection".localized) {
                    guard let profile = ProfileManager.shared.activeProfile,
                          let key = apiKey.nilIfBlank else { return }
                    testing = true
                    error = nil
                    Task {
                        defer { testing = false }
                        do {
                            let snapshot = try await ZAIAPIService().fetchUsage(apiKey: key)
                            guard var current = ProfileManager.shared.activeProfile,
                                  current.id == profile.id, current.provider == profile.provider, apiKey.nilIfBlank == key else { return }
                            current.provider = .zai
                            current.zaiAPIKey = key
                            current.zaiUsage = snapshot
                            current.claudeUsage = snapshot.sharedUsage(configuration: current.zaiConfiguration)
                            guard ProfileManager.shared.updateProfile(current) else {
                                self.error = ProfileManager.shared.storageError
                                return
                            }
                            onDone()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(testing || apiKey.nilIfBlank == nil)
            }
            if testing { ProgressView() }
        }
        .padding(40).frame(width: 580, height: 680)
    }
}
