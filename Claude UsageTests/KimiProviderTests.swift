import XCTest
@testable import Claude_Usage

@MainActor
final class KimiProviderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_793_600_000)
    private let fixture = Data(#"{"usages":{"limit_5h":{"used_ratio":"0.25","reset_time":"2027-01-01T12:00:00.123Z"},"limit_month_total":{"used_ratio":0.6,"reset_time":"2027-02-01T00:00:00Z"},"limit_month_code":{"used_ratio":0.2}},"unknown":{"future":true}}"#.utf8)

    func testModernMonthlyPlanPreservesWindowIdentityAndTiming() throws {
        let snapshot = try KimiAPIService.parse(data: fixture, fetchedAt: date)
        let usage = snapshot.sharedUsage(configuration: .init())
        XCTAssertEqual(usage.quotaWindows?.map(\.id), ["limit_5h", "limit_month_total", "limit_month_code"])
        XCTAssertEqual(usage.sessionPercentage, 25)
        XCTAssertEqual(usage.weeklyAvailable, false)
        XCTAssertEqual(usage.quotaWindows?[1].usedPercentage, 60)
        XCTAssertEqual(usage.quotaWindows?[2].usedPercentage, 20)
        XCTAssertEqual(usage.sessionTokensUsed, 0)
        XCTAssertEqual(usage.weeklyLimit, 0)
        XCTAssertNil(usage.quotaWindows?[1].durationMinutes)
        XCTAssertNotNil(usage.quotaWindows?[0].resetTime)
        XCTAssertNil(usage.quotaWindows?[2].resetTime)
        XCTAssertEqual(usage.lastUpdated, date)
    }

    func testMissingMalformedAndBooleanRatiosAreUnavailable() throws {
        for ratio in ["true", "null", "\"NaN\"", "-0.2", "{}"] {
            let data = Data("{\"usages\":{\"limit_5h\":{\"used_ratio\":\(ratio)},\"limit_month_total\":{\"used_ratio\":0.4}}}".utf8)
            let usage = try KimiAPIService.parse(data: data, fetchedAt: date).sharedUsage(configuration: .init())
            XCTAssertFalse(usage.sessionAvailable!)
            XCTAssertFalse(usage.weeklyAvailable!)
            XCTAssertEqual(usage.primaryQuota?.id, "limit_month_total")
            XCTAssertNil(usage.primaryQuota?.resetTime)
        }
        for value in ["{}", "[]", "{\"error\":{}}", "{\"usages\":{}}"] {
            XCTAssertThrowsError(try KimiAPIService.parse(data: Data(value.utf8), fetchedAt: date))
        }
    }

    func testOptionalWeeklyPlanAndMonthlySelectionDoNotRewriteHistoryValues() throws {
        let data = Data(#"{"usages":{"limit_7d":{"used_ratio":0.35},"limit_month_total":{"used_ratio":0.7}}}"#.utf8)
        let usage = try KimiAPIService.parse(data: data, fetchedAt: date).sharedUsage(configuration: .init(selectedQuotaID: "limit_month_total"))
        XCTAssertEqual(usage.weeklyPercentage, 35)
        XCTAssertEqual(usage.sessionAvailable, false)
        XCTAssertEqual(usage.trayUsage.sessionPercentage, 70)
        XCTAssertNil(usage.primaryElapsedFraction())
        XCTAssertFalse(usage.hasPrimaryReset)
    }

    func testLegacyStringCountsAndModernZeroPrecedence() throws {
        let legacy = #"{"usage":{"limit":"100","remaining":"75"},"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"20","remaining":"10","resetTime":"2027-01-01T12:00:00Z"}}]}"#
        let usage = try KimiAPIService.parse(data: Data(legacy.utf8), fetchedAt: date).sharedUsage(configuration: .init())
        XCTAssertEqual(usage.sessionPercentage, 50)
        XCTAssertEqual(usage.weeklyPercentage, 25)
        let data = Data(#"{"usages":{"limit_5h":{"used_ratio":0}},"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"20","remaining":"0"}}]}"#.utf8)
        XCTAssertEqual(try KimiAPIService.parse(data: data, fetchedAt: date).quotas.first?.usedPercentage, 0)
        XCTAssertThrowsError(try KimiAPIService.parse(data: Data(#"{"usage":{"limit":"0","remaining":"0"}}"#.utf8), fetchedAt: date))
    }

    func testInconsistentMonthlyShareIsOmittedAndOverageIsClamped() throws {
        let data = Data(#"{"usages":{"limit_5h":{"used_ratio":1.2},"limit_month_total":{"used_ratio":0.2},"limit_month_code":{"used_ratio":0.8}}}"#.utf8)
        let snapshot = try KimiAPIService.parse(data: data, fetchedAt: date)
        XCTAssertEqual(snapshot.quotas.first?.usedPercentage, 100)
        XCTAssertFalse(snapshot.quotas.contains { $0.id == "limit_month_code" })
    }

    func testOpenCodeV2SelectsOnlyActiveAccountAndExactRegion() throws {
        let data = Data(#"[{"integrationID":"opencode-go","active":true,"value":{"type":"key","key":"wrong"}},{"integrationID":"kimi-code-plan-cn","active":true,"value":{"type":"key","key":"china"}},{"integrationID":"kimi-code-plan-global","active":false,"value":{"type":"key","key":"old"}},{"integrationID":"kimi-code-plan-global","active":true,"value":{"type":"key","key":"synthetic-global"}}]"#.utf8)
        XCTAssertEqual(try KimiAuthService.parse(data, region: .global), "synthetic-global")
        XCTAssertEqual(try KimiAuthService.parse(data, region: .china), "china")
        let duplicate = Data(#"[{"integrationID":"kimi-code-plan-global","active":true},{"integrationID":"kimi-code-plan-global","active":true}]"#.utf8)
        XCTAssertThrowsError(try KimiAuthService.parse(duplicate, region: .global)) { XCTAssertEqual($0 as? KimiError, .ambiguousAccounts) }
        XCTAssertThrowsError(try KimiAuthService.parse(Data("[]".utf8), region: .global))
    }

    func testLegacyImportDoesNotConfuseGoOrMoonshotWithKimi() throws {
        let legacy = Data(#"{"kimi-for-coding":{"type":"api","key":"synthetic-cn"},"opencode-go":{"type":"api","key":"go"},"moonshotai":{"type":"api","key":"platform"}}"#.utf8)
        XCTAssertEqual(try KimiAuthService.parse(legacy, region: .china), "synthetic-cn")
        XCTAssertThrowsError(try KimiAuthService.parse(legacy, region: .global))
    }

    func testRequestHostHeadersAndCurrentSelectionProjection() async throws {
        let service = KimiAPIService(now: { self.date }, transport: { request in
            XCTAssertEqual(request.url?.host, "api.kimi.ai")
            XCTAssertEqual(request.url?.path, "/coding/v1/usages")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")!.hasPrefix("Claude-Usage-Tracker/"))
            return (self.fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let provider = KimiUsageProvider(service: service)
        var profile = Profile(name: "Kimi", provider: .kimi, kimiAPIKey: "synthetic")
        let result = try await provider.fetchResult(for: profile, active: false)
        profile.kimiConfiguration.selectedQuotaID = "limit_month_total"
        XCTAssertEqual(result.projectUsage?(profile).trayUsage.sessionPercentage, 60)
        XCTAssertEqual(KimiRegion.china.usageURL.host, "api.kimi.com")
    }

    func testRetryAfterPreventsPollingAndIsIsolatedByKey() async throws {
        var now = date
        var requests = 0
        let service = KimiAPIService(now: { now }, transport: { request in
            requests += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        })
        for _ in 0..<2 {
            do { _ = try await service.fetchUsage(apiKey: "synthetic", region: .global); XCTFail() }
            catch { XCTAssertEqual(error as? KimiError, .retryLater) }
        }
        XCTAssertEqual(requests, 1)
        now.addTimeInterval(121)
        _ = try? await service.fetchUsage(apiKey: "synthetic", region: .global)
        XCTAssertEqual(requests, 2)
        _ = try? await service.fetchUsage(apiKey: "other", region: .global)
        XCTAssertEqual(requests, 3)
    }

    func testAuthenticationAndMalformedResponsesAreFailures() async throws {
        for code in [401, 403, 500, 200] {
            let service = KimiAPIService(transport: { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            })
            do { _ = try await service.fetchUsage(apiKey: "synthetic", region: .global); XCTFail("Failure became an empty fresh quota") }
            catch { if code == 401 || code == 403 { XCTAssertEqual((error as? AppError)?.code, .providerAuthExpired) } }
        }
    }

    func testProfileSecretExclusionFallbackAndIdentity() throws {
        var profile = Profile(name: "Kimi", provider: .kimi, kimiAPIKey: "synthetic-secret")
        let identity = ProfileAccountIdentity(profile)
        profile.name = "Renamed"
        profile.kimiConfiguration.selectedQuotaID = "limit_month_total"
        XCTAssertEqual(ProfileAccountIdentity(profile), identity)
        profile.kimiConfiguration.region = .china
        XCTAssertNotEqual(ProfileAccountIdentity(profile), identity)
        profile.kimiConfiguration.region = .global
        profile.kimiAPIKey = "replacement"
        XCTAssertNotEqual(ProfileAccountIdentity(profile), identity)
        XCTAssertFalse(String(data: try JSONEncoder().encode(profile), encoding: .utf8)!.contains("replacement"))
        let encoder = JSONEncoder(); encoder.userInfo[Profile.includeSecretsKey] = true
        let decoded = try JSONDecoder().decode(Profile.self, from: encoder.encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testWidgetShowsFiveHourAndMonthlyWithoutInventingWeekly() throws {
        let usage = try KimiAPIService.parse(data: fixture, fetchedAt: date).sharedUsage(configuration: .init())
        let profile = Profile(name: "Kimi", provider: .kimi, kimiAPIKey: "synthetic", claudeUsage: usage)
        var snapshot: WidgetSnapshot?
        let service = WidgetSnapshotService(now: { self.date }, writeSnapshot: { snapshot = $0 }, requestReload: {})
        service.publish(profiles: [profile], activeProfileId: profile.id)
        let row = try XCTUnwrap(snapshot?.profiles.first)
        XCTAssertEqual(row.provider, .kimi)
        XCTAssertEqual(row.sessionPercentage, 25)
        XCTAssertEqual(row.weeklyPercentage, 60)
        XCTAssertEqual(row.primaryLabel, "widget.session")
        XCTAssertEqual(row.secondaryLabel, "widget.monthly")
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot!)).profiles.first?.provider, .kimi)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        try snapshot!.write(to: file)
        let loaded = try XCTUnwrap(WidgetSnapshot.load(from: file))
        XCTAssertEqual(loaded.profiles.first?.secondaryLabel, "widget.monthly")
        var selected = profile
        selected.claudeUsage?.selectedQuotaID = "limit_month_code"
        service.publish(profiles: [selected], activeProfileId: selected.id)
        try snapshot!.write(to: file)
        XCTAssertEqual(WidgetSnapshot.load(from: file)?.profiles.first?.primaryLabel, "widget.monthly_code")
    }

    func testChangedCredentialRejectsInflightRefresh() async {
        var profile = Profile(name: "Kimi", provider: .kimi, kimiAPIKey: "first")
        var pending: CheckedContinuation<UsageProviderResult, Error>?
        let coordinator = ProfileRefreshCoordinator { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let source = profile
        let task = Task { await coordinator.refresh(source, active: false) { $0 == ProfileAccountIdentity(profile) } }
        for _ in 0..<1000 { if pending != nil { break }; await Task.yield() }
        guard let pending else { XCTFail("Refresh not started"); task.cancel(); return }
        profile.kimiAPIKey = "second"
        pending.resume(returning: UsageProviderResult(usage: .empty))
        if case .superseded = await task.value {} else { XCTFail("Stale key response accepted") }
    }

    func testImportSubprocessTimesOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("opencode")
        try Data("#!/bin/sh\nexec /bin/sleep 3\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = Date()
        do { _ = try await KimiAuthService.export(executable: script, region: .global, home: directory, timeout: 0.1); XCTFail() }
        catch { XCTAssertEqual(error as? KimiError, .importFailed) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
