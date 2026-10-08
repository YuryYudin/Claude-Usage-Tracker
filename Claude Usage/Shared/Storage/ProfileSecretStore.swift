import Foundation

protocol ProfileSecretStore {
    func loadProfileSecret(profileId: UUID, field: KeychainService.ProfileSecretField) -> String?
    func saveProfileSecret(_ value: String?, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool
    func verifyProfileSecret(_ expected: String, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool
    func deleteAllProfileSecrets(profileId: UUID)
}

extension KeychainService: ProfileSecretStore {}

/// Hosted tests never hydrate or mutate the production Keychain.
final class MemoryProfileSecretStore: ProfileSecretStore {
    private var items: [String: String] = [:]
    func loadProfileSecret(profileId: UUID, field: KeychainService.ProfileSecretField) -> String? {
        items["\(profileId).\(field.rawValue)"]
    }
    func saveProfileSecret(_ value: String?, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool {
        items["\(profileId).\(field.rawValue)"] = value
        return true
    }
    func verifyProfileSecret(_ expected: String, profileId: UUID, field: KeychainService.ProfileSecretField) -> Bool {
        loadProfileSecret(profileId: profileId, field: field) == expected
    }
    func deleteAllProfileSecrets(profileId: UUID) {
        for field in KeychainService.ProfileSecretField.allCases {
            _ = saveProfileSecret(nil, profileId: profileId, field: field)
        }
    }
}
