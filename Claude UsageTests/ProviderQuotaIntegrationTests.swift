import XCTest
@testable import Claude_Usage

@MainActor
final class ProviderQuotaIntegrationTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func zaiSnapshot() -> ZAIUsage {
        ZAIUsage(account: ZAIAccount(planType: "pro"), rateLimits: [
            ZAIRateLimit(id: "CREDIT_LIMIT-3", name: "Five hours", kind: .tokens,
                primary: .init(usedPercent: 12, windowDurationMinutes: 300, resetsAt: nil, usedCredits: 120, totalCredits: 1000)),
            ZAIRateLimit(id: "CREDIT_LIMIT-6", name: "Weekly", kind: .tokens,
                primary: .init(usedPercent: 34, windowDurationMinutes: 10080, resetsAt: nil, usedCredits: 340, totalCredits: 1000)),
            ZAIRateLimit(id: "TIME_LIMIT-5", name: "Monthly tools", kind: .toolCalls,
                primary: .init(usedPercent: 56, windowDurationMinutes: nil, resetsAt: nil, usedCredits: 56, totalCredits: 100))
        ], lastUpdated: fetchedAt)
    }

    func testMonthlyToolsDriveTrayWithoutChangingSessionOrWeeklyHistory() throws {
        let usage = zaiSnapshot().sharedUsage(configuration: .init(selectedLimitID: "TIME_LIMIT-5"))
        XCTAssertEqual(usage.sessionPercentage, 12)
        XCTAssertEqual(usage.weeklyPercentage, 34)
        XCTAssertEqual(usage.trayUsage.sessionPercentage, 56)
        XCTAssertEqual(usage.primaryQuota?.role, .tools)
        XCTAssertEqual(usage.primaryQuota?.consumed, 56)
        XCTAssertEqual(usage.primaryQuota?.unit, "calls")
        XCTAssertNil(usage.primaryQuota?.resetTime)
        XCTAssertEqual(usage.lastUpdated, fetchedAt)
        let decoded = try JSONDecoder().decode(ClaudeUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(decoded.quotaWindows, usage.quotaWindows)
        XCTAssertEqual(decoded.selectedQuotaID, "TIME_LIMIT-5")
    }

    func testLegacyTokenSelectionResolvesCreditResponse() {
        let usage = zaiSnapshot().sharedUsage(configuration: .init(selectedLimitID: "TOKENS_LIMIT-6"))
        XCTAssertEqual(usage.selectedQuotaID, "CREDIT_LIMIT-6")
        XCTAssertEqual(usage.trayUsage.sessionPercentage, 34)
    }

    func testCodexRetainsEveryNamedBucketAndMissingResets() {
        let snapshot = CodexUsage(account: .init(email: "synthetic@example.com", planType: "pro"), rateLimits: [
            .init(id: "codex", name: "General", primary: .init(usedPercent: 11, windowDurationMinutes: 300, resetsAt: nil),
                secondary: .init(usedPercent: 22, windowDurationMinutes: 10080, resetsAt: nil), credits: nil, planType: nil, reachedType: nil),
            .init(id: "named", name: "Named model", primary: .init(usedPercent: 33, windowDurationMinutes: 300, resetsAt: nil),
                secondary: .init(usedPercent: 44, windowDurationMinutes: 10080, resetsAt: nil), credits: nil, planType: nil, reachedType: nil)
        ], tokenUsage: nil, lastUpdated: fetchedAt)
        let usage = snapshot.sharedUsage(configuration: .init(selectedRateLimitID: "named"))
        XCTAssertEqual(usage.quotaWindows?.count, 4)
        XCTAssertEqual(usage.primaryQuota?.bucketID, "named")
        XCTAssertEqual(usage.sessionPercentage, 33)
        XCTAssertEqual(usage.weeklyPercentage, 44)
        XCTAssertTrue(usage.quotaWindows!.allSatisfy { $0.resetTime == nil })
        XCTAssertEqual(usage.lastUpdated, fetchedAt)
        var published: WidgetSnapshot?
        let publisher = WidgetSnapshotService(writeSnapshot: { published = $0 }, requestReload: {})
        let profile = Profile(name: "Named model", provider: .codex,
            codexConfiguration: .init(selectedRateLimitID: "named"), claudeUsage: usage)
        publisher.publish(profiles: [profile], activeProfileId: profile.id)
        XCTAssertEqual(published?.profiles.first?.sessionPercentage, 33)
        XCTAssertEqual(published?.profiles.first?.weeklyPercentage, 44)
    }

    func testHTTPWeeklyOnlyUsageHasNoInventedSessionAndPublishesWeekly() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(#"{"rate_limit":{"primary_window":{"used_percent":73,"limit_window_seconds":604800}}}"#.utf8))
        let usage = CodexAPIService.mapToUsage(response)
        XCTAssertEqual(usage.sessionAvailable, false)
        XCTAssertEqual(usage.weeklyAvailable, true)
        XCTAssertEqual(usage.trayUsage.sessionPercentage, 73)
        XCTAssertEqual(usage.primaryQuota?.role, .weekly)
        XCTAssertNil(usage.primaryQuota?.resetTime)
        var published: WidgetSnapshot?
        let publisher = WidgetSnapshotService(writeSnapshot: { published = $0 }, requestReload: {})
        let profile = Profile(name: "Weekly only", provider: .codex, codexCredentialsJSON: "synthetic", claudeUsage: usage)
        publisher.publish(profiles: [profile], activeProfileId: profile.id)
        XCTAssertEqual(published?.profiles.first?.sessionPercentage, 73)
        XCTAssertEqual(published?.profiles.first?.primaryLabel, "widget.weekly")
        XCTAssertNil(published?.profiles.first?.sessionResetTime)
        XCTAssertNil(published?.profiles.first?.weeklyPercentage)
    }

    func testSnapshotDoesNotPublishAnAbsentQuotaAsZero() {
        var usage = ClaudeUsage.empty
        usage.sessionAvailable = false; usage.weeklyAvailable = false
        usage.quotaWindows = []
        let profile = Profile(name: "Empty", provider: .codex, codexConfiguration: .init(), claudeUsage: usage)
        var published: WidgetSnapshot?
        let publisher = WidgetSnapshotService(writeSnapshot: { published = $0 }, requestReload: {})
        publisher.publish(profiles: [profile], activeProfileId: profile.id)
        XCTAssertEqual(published?.profiles.count, 0)
    }

    func testZAIProviderUsesCurrentSelectionWhenARequestFinishes() async throws {
        let fixture = Data(#"{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":12},{"type":"TIME_LIMIT","unit":5,"percentage":56}]}}"#.utf8)
        let service = ZAIAPIService(dataProvider: { request in
            (fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let source = Profile(name: "Synthetic", provider: .zai, zaiAPIKey: "synthetic-key")
        let result = try await ZAIUsageProvider(service: service).fetchResult(for: source, active: false)
        var current = source
        current.zaiConfiguration.selectedLimitID = "TIME_LIMIT-5"
        result.updateDetails(&current)
        let usage = try XCTUnwrap(result.projectUsage?(current))
        XCTAssertEqual(usage.primaryQuota?.role, .tools)
        XCTAssertEqual(usage.trayUsage.sessionPercentage, 56)
        XCTAssertNotNil(current.zaiUsage)
    }

    func testTestsUseIsolatedStorageAndUpdateChannel() {
        XCTAssertTrue(AppEnvironment.isTesting)
        XCTAssertNotIdentical(UserDefaults.appStorage, UserDefaults.standard)
        XCTAssertTrue(AppEnvironment.applicationSupport.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(Constants.NotchHUD.port, 29847)
        XCTAssertFalse(UpdateManager.updatesAvailable)
    }
    func testSelectedWeeklyQuotaUsesWeeklyPaceAndMissingTimingHidesMarkers() throws {
        var usage = zaiSnapshot().sharedUsage(configuration: .init(selectedLimitID: "CREDIT_LIMIT-6"))
        let reset = Date().addingTimeInterval(3.5 * 24 * 60 * 60)
        usage.quotaWindows?[1].resetTime = reset
        let fraction = try XCTUnwrap(usage.trayUsage.primaryElapsedFraction())
        XCTAssertEqual(fraction, 0.5, accuracy: 0.001)
        XCTAssertTrue(usage.hasPrimaryReset)
        usage.selectedQuotaID = "TIME_LIMIT-5"
        XCTAssertNil(usage.trayUsage.primaryElapsedFraction())
        XCTAssertFalse(usage.hasPrimaryReset)
        usage.quotaWindows?[2].resetTime = reset
        XCTAssertNil(usage.trayUsage.primaryElapsedFraction(), "An unknown monthly duration must not become a five-hour window")
        XCTAssertTrue(usage.hasPrimaryReset)
    }

    func testAccountWithoutCacheNeverDisplaysAPlaceholderQuota() {
        let profile = Profile(name: "No cache", provider: .zai, zaiAPIKey: "synthetic")
        XCTAssertEqual(profile.usageForDisplay.sessionAvailable, false)
        XCTAssertEqual(profile.usageForDisplay.weeklyAvailable, false)
        var other = profile
        var fetched = ClaudeUsage.empty; fetched.sessionPercentage = 67
        other.claudeUsage = fetched
        XCTAssertEqual(other.usageForDisplay.sessionPercentage, 67)
        XCTAssertEqual(profile.usageForDisplay.sessionAvailable, false)
    }

}
