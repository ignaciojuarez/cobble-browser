import CloudKit
import XCTest
@testable import Cobble

final class CloudKitSyncProviderTests: XCTestCase {
    @MainActor func testInvalidOutboundRecordsFailBeforeAccessingAccount() async {
        let provider = CloudKitSyncProvider()
        let invalid = SyncRecord(id: "", module: .bookmarks, kind: "bookmark")
        do {
            _ = try await provider.save([invalid], module: .bookmarks, expectedAccountID: "test")
            XCTFail("Invalid records must not reach CloudKit")
        } catch SyncFailure.invalidRecord {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor func testNestedPartialFailurePreservesServerBackoff() throws {
        let retry = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 120.0])
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["record": retry]])
        let before = Date()
        let result = try XCTUnwrap(CloudKitSyncProvider().retryError(partial) as? SyncRetryFailure)
        XCTAssertGreaterThanOrEqual(result.retryAfter.timeIntervalSince(before), 120)
    }

    @MainActor func testCancelledTaskDoesNotAccessCloudKit() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CloudKitSyncProvider().accountID()
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled provider must not access an account")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
