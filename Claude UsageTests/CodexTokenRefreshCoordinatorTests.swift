import XCTest
@testable import Claude_Usage

@MainActor
final class CodexTokenRefreshCoordinatorTests: XCTestCase {
    private func credentials(_ token: String) -> CodexCredentials {
        .init(accessToken: "synthetic-access", refreshToken: token, idToken: nil, accountId: "synthetic-account", lastRefresh: nil)
    }

    func testConcurrentAndLateCallersNeverReuseRotatedToken() async throws {
        var requests = 0
        var pending: CheckedContinuation<CodexCredentials, Error>?
        let coordinator = CodexTokenRefreshCoordinator { _ in
            requests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        let original = credentials("original")
        let first = Task { try await coordinator.refresh(original) }
        while pending == nil { await Task.yield() }
        let second = Task { try await coordinator.refresh(original) }
        await Task.yield()
        pending!.resume(returning: credentials("rotated"))
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.refreshToken, "rotated")
        XCTAssertEqual(secondResult.refreshToken, "rotated")
        let late = try await coordinator.refresh(original)
        XCTAssertEqual(late.refreshToken, "rotated")
        XCTAssertEqual(requests, 1)
    }

    func testRotationsFollowLatestTokenAndKeepAccountsSeparate() async throws {
        var requests: [String] = []
        let coordinator = CodexTokenRefreshCoordinator { input in
            requests.append(input.refreshToken)
            return self.credentials(input.refreshToken + "-next")
        }
        _ = try await coordinator.refresh(credentials("a"))
        _ = try await coordinator.refresh(credentials("a-next"))
        _ = try await coordinator.refresh(credentials("b"))
        let latest = try await coordinator.refresh(credentials("a"))
        XCTAssertEqual(latest.refreshToken, "a-next-next")
        XCTAssertEqual(requests, ["a", "a-next", "b"])
    }

    func testFailedNetworkRequestCanRetry() async throws {
        var attempts = 0
        let coordinator = CodexTokenRefreshCoordinator { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.timedOut) }
            return self.credentials("rotated")
        }
        do { _ = try await coordinator.refresh(credentials("a")); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is URLError) }
        let next = try await coordinator.refresh(credentials("a"))
        XCTAssertEqual(next.refreshToken, "rotated")
        XCTAssertEqual(attempts, 2)
    }
    func testWritebackAcceptsOwnEarlierRotationButRejectsAnotherLogin() {
        let first = credentials("first")
        let second = credentials("second")
        let third = credentials("third")
        XCTAssertTrue(CredentialRefreshGuard.canUpdateCodex(second, expected: second, replacement: third))
        XCTAssertTrue(CredentialRefreshGuard.canUpdateCodex(third, expected: second, replacement: third))
        XCTAssertFalse(CredentialRefreshGuard.canUpdateCodex(first, expected: second, replacement: third))
        var anotherAccount = second
        anotherAccount.accountId = "different-account"
        XCTAssertFalse(CredentialRefreshGuard.canUpdateCodex(anotherAccount, expected: second, replacement: third))
    }

}
