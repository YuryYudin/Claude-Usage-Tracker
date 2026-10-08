import Foundation

enum AppEnvironment {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_USAGE_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static let defaults: UserDefaults = {
        guard isTesting else { return .standard }
        return UserDefaults(suiteName: "com.claudeusagetracker.tests.\(UUID().uuidString)")!
    }()

    static let applicationSupport: URL = {
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-usage-tests-\(UUID().uuidString)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Usage")
    }()
}

extension UserDefaults {
    static var appStorage: UserDefaults { AppEnvironment.defaults }
}
