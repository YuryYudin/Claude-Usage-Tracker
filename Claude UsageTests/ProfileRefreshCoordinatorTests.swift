import XCTest
@testable import Claude_Usage

@MainActor
final class ProfileRefreshCoordinatorTests: XCTestCase {
    private var pending: [CheckedContinuation<UsageProviderResult, Error>] = []

    private func coordinator() -> ProfileRefreshCoordinator {
        ProfileRefreshCoordinator(fetch: { _, _ in
            try await withCheckedThrowingContinuation { self.pending.append($0) }
        })
    }

    private func waitForRequests(_ count: Int) async {
        for _ in 0..<1000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        XCTFail("Refresh did not start")
    }

    func testChangedKeyRejectsOldResponse() async {
        let source = Profile(name: "Synthetic", provider: .zai, zaiAPIKey: "key-a")
        var current = source
        let coordinator = coordinator()
        let task = Task { await coordinator.refresh(source, active: true, isCurrent: { $0 == ProfileAccountIdentity(current) }) }
        await waitForRequests(1)
        current.zaiAPIKey = "key-b"
        pending.removeFirst().resume(returning: UsageProviderResult(usage: .empty))
        if case .superseded = await task.value {} else { XCTFail("Old account data accepted") }
        XCTAssertFalse(coordinator.isRefreshing)
    }

    func testSwitchingActiveAccountDoesNotChangeResultOwnership() async {
        let source = Profile(name: "A", provider: .zai, zaiAPIKey: "key-a")
        let other = Profile(name: "B", provider: .zai, zaiAPIKey: "key-b")
        let profiles = [source, other]
        var activeID = source.id
        let coordinator = coordinator()
        let task = Task { await coordinator.refresh(source, active: true, isCurrent: { identity in
            profiles.contains { ProfileAccountIdentity($0) == identity }
        }) }
        await waitForRequests(1)
        activeID = other.id
        pending.removeFirst().resume(returning: UsageProviderResult(usage: .empty))
        if case .updated = await task.value {} else { XCTFail("Unchanged source account should accept its own result") }
        XCTAssertEqual(activeID, other.id)
    }

    func testNewerRefreshWinsWhenOlderRequestFinishesLast() async {
        let source = Profile(name: "A", provider: .zai, zaiAPIKey: "key")
        let coordinator = coordinator()
        let first = Task { await coordinator.refresh(source, active: true, isCurrent: { _ in true }) }
        await waitForRequests(1)
        let second = Task { await coordinator.refresh(source, active: true, isCurrent: { _ in true }) }
        await waitForRequests(2)
        pending.removeLast().resume(returning: UsageProviderResult(usage: .empty))
        if case .updated = await second.value {} else { XCTFail("Latest response rejected") }
        pending.removeFirst().resume(returning: UsageProviderResult(usage: .empty))
        if case .superseded = await first.value {} else { XCTFail("Older response accepted") }
    }

    func testDeletedProfileRejectsFailureWithoutReplacingCurrentErrors() async {
        let source = Profile(name: "A", provider: .zai, zaiAPIKey: "key")
        var exists = true
        let coordinator = coordinator()
        let task = Task { await coordinator.refresh(source, active: true, isCurrent: { _ in exists }) }
        await waitForRequests(1)
        exists = false
        pending.removeFirst().resume(throwing: ZAIAPIServiceError.invalidKey("synthetic"))
        if case .superseded = await task.value {} else { XCTFail("Deleted profile's error accepted") }
    }

    func testPresentationEditsKeepAccountIdentityButConnectionEditsDoNot() {
        var profile = Profile(name: "A", provider: .codex,
            codexConfiguration: CodexProfileConfiguration(connectionType: .ssh, codexHome: "/a", sshHost: "host"))
        let original = ProfileAccountIdentity(profile)
        profile.name = "Renamed"
        profile.codexConfiguration?.selectedRateLimitID = "other"
        XCTAssertEqual(ProfileAccountIdentity(profile), original)
        profile.codexConfiguration?.codexHome = "/b"
        XCTAssertNotEqual(ProfileAccountIdentity(profile), original)
    }

    func testInactiveSelectionAndAutoSwitchStayAccountAndProviderSpecific() {
        let active = Profile(name: "A", claudeSessionKey: "synthetic-a", organizationId: "org-a")
        let codex = Profile(name: "Codex", provider: .codex, codexConfiguration: CodexProfileConfiguration())
        let zai = Profile(name: "GLM", provider: .zai, zaiAPIKey: "synthetic-z")
        let next = Profile(name: "B", claudeSessionKey: "synthetic-b", organizationId: "org-b")
        let hidden = Profile(name: "Hidden", provider: .zai, zaiAPIKey: "synthetic-h", isSelectedForDisplay: false)
        let profiles = [active, codex, zai, next, hidden]
        XCTAssertEqual(ProfileRefreshPolicy.inactiveDisplayed(profiles, activeID: active.id).map(\.id), [codex.id, zai.id, next.id])
        XCTAssertEqual(ProfileRefreshPolicy.autoSwitchCandidate(profiles, after: active)?.id, next.id)
        XCTAssertNil(ProfileRefreshPolicy.autoSwitchCandidate(profiles, after: codex))
        XCTAssertNil(ProfileRefreshPolicy.autoSwitchCandidate(profiles, after: zai))
    }
}
