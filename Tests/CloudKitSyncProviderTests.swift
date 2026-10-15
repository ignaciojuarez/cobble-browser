import CloudKit
import XCTest
@testable import Cobble

final class CloudKitSyncProviderTests: XCTestCase {
    @MainActor func testSecretOrganizationURLsAndTombstonesFailBeforeAccessingAccount() async throws {
        let stamp = SyncStamp(counter: 1, deviceID: "fixture")
        for deleted in [false, true] {
            let record = SyncRecord(id: "saved.fixture", module: .organization, kind: "saved",
                fields: ["url": SyncField(value: "https://example.com/?access_token=fixture", stamp: stamp)],
                tombstone: deleted ? stamp : nil)
            do {
                _ = try await CloudKitSyncProvider().save([record], module: .organization, expectedAccountID: "test")
                XCTFail("Secret URLs must not reach CloudKit")
            } catch SyncFailure.invalidRecord {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor func testConflictMergeCannotReintroduceAnUnsafeOrganizationURLForUpload() throws {
        let local = SyncRecord(id: "saved.fixture", module: .organization, kind: "saved", fields: [
            "url": SyncField(value: "https://example.com/", stamp: SyncStamp(counter: 1, deviceID: "local"))])
        var cloud = local
        cloud.fields["url"] = SyncField(value: "https://example.com/#token=fixture",
                                        stamp: SyncStamp(counter: 2, deviceID: "remote"))
        XCTAssertNoThrow(try local.validateOrganizationURL())
        let merged = try local.merged(with: cloud)
        XCTAssertThrowsError(try merged.validateOrganizationURL())
    }

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
