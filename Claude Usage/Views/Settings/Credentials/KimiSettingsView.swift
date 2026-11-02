import SwiftUI

@MainActor
struct KimiSettingsView: View {
    @StateObject private var manager = ProfileManager.shared

    var body: some View {
        if let profile = manager.activeProfile, profile.provider == .kimi {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsPageHeader(title: "kimi.title".localized, subtitle: "kimi.subtitle".localized)
                    KimiConnectionEditor(profileID: profile.id)
                        .id(profile.id)
                    if let usage = profile.claudeUsage, let quotas = usage.quotaWindows {
                        SettingsSectionCard(title: "kimi.quota.selection".localized) {
                            Picker("kimi.quota.selection".localized, selection: Binding(
                                get: { profile.kimiConfiguration.selectedQuotaID ?? "" },
                                set: { selected in
                                    guard var current = manager.profiles.first(where: { $0.id == profile.id }) else { return }
                                    current.kimiConfiguration.selectedQuotaID = selected.nilIfBlank
                                    current.claudeUsage?.selectedQuotaID = selected.nilIfBlank
                                    if manager.updateProfile(current) {
                                        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                                    }
                                }
                            )) {
                                Text("codex.settings.automatic".localized).tag("")
                                ForEach(quotas) { Text($0.label).tag($0.id) }
                            }
                            .labelsHidden()
                            Text(usage.lastUpdated.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
        }
    }
}

@MainActor
struct KimiSetupView: View {
    let onDone: () -> Void
    let onBack: () -> Void
    @StateObject private var manager = ProfileManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "kimi.title".localized, subtitle: "kimi.subtitle".localized)
            if let id = manager.activeProfile?.id {
                KimiConnectionEditor(profileID: id, onSaved: onDone).id(id)
            }
            Spacer()
            Button("common.back".localized, action: onBack)
        }
        .padding(32).frame(width: 580, height: 680)
    }
}

/// Both setup and settings bind a tested key to one explicit profile. Import
/// populates the draft; nothing is persisted until Test and Save succeeds.
@MainActor
private struct KimiConnectionEditor: View {
    let profileID: UUID
    var onSaved: () -> Void = {}
    @StateObject private var manager = ProfileManager.shared
    @State private var apiKey = ""
    @State private var region = KimiRegion.global
    @State private var executablePath = ""
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var service = KimiAPIService()

    private var profile: Profile? { manager.profiles.first { $0.id == profileID } }
    private var storedKey: String? { profile?.kimiAPIKey?.nilIfBlank }

    var body: some View {
        SettingsSectionCard(title: "kimi.connection".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("kimi.region".localized, selection: $region) {
                    ForEach(KimiRegion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SecureField(storedKey == nil ? "kimi.key".localized : "kimi.key.keep".localized, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                DisclosureGroup("kimi.import.options".localized) {
                    TextField("kimi.import.path".localized, text: $executablePath)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("kimi.import".localized, action: importKey)
                    Button("kimi.save".localized, action: testAndSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.nilIfBlank == nil && storedKey == nil)
                    if busy { ProgressView().controlSize(.small) }
                }
                if storedKey != nil {
                    Label("kimi.saved".localized, systemImage: "key.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("kimi.remove".localized, role: .destructive, action: removeKey)
                }
                if let message = errorMessage ?? MenuBarManager.current?.providerErrors[profileID] {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Text("kimi.help".localized).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("kimi.console".localized, destination: URL(string: region == .global
                    ? "https://www.kimi.ai/code/console" : "https://www.kimi.com/code/console")!)
            }
            .disabled(busy)
        }
        .onAppear { region = profile?.kimiConfiguration.region ?? .global }
        .onDisappear { operation?.cancel() }
    }

    private func importKey() {
        busy = true
        errorMessage = nil
        let selectedRegion = region
        let executable = executablePath.nilIfBlank
        operation = Task {
            defer { busy = false }
            do {
                let key = try await KimiAuthService.importFromOpenCode(region: selectedRegion, executablePath: executable)
                try Task.checkCancellation()
                apiKey = key
            } catch is CancellationError {} catch {
                errorMessage = (error as? KimiError ?? .importFailed).localizedDescription
            }
        }
    }

    private func testAndSave() {
        guard let original = profile, let key = apiKey.nilIfBlank ?? storedKey else { return }
        let identity = ProfileAccountIdentity(original)
        let selectedRegion = region
        busy = true
        errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                let snapshot = try await service.fetchUsage(apiKey: key, region: selectedRegion)
                try Task.checkCancellation()
                guard var current = profile, ProfileAccountIdentity(current) == identity else { return }
                current.provider = .kimi
                current.kimiAPIKey = key
                current.kimiConfiguration.region = selectedRegion
                current.claudeUsage = snapshot.sharedUsage(configuration: current.kimiConfiguration)
                guard manager.updateProfile(current) else {
                    errorMessage = manager.storageError
                    return
                }
                apiKey = ""
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                onSaved()
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    private func removeKey() {
        guard var current = profile else { return }
        current.kimiAPIKey = nil
        current.claudeUsage = nil
        if manager.updateProfile(current) {
            apiKey = ""
            errorMessage = nil
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        } else { errorMessage = manager.storageError }
    }
}
