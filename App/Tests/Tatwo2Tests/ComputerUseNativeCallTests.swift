import Foundation
import XCTest
@testable import Tatwo2

@MainActor
final class ComputerUseNativeCallTests: XCTestCase {
    func testCallbackResultReleasesSlot() async throws {
        let call = ComputerUseNativeCall()
        let value: Int = try await call.run(deadline: ProcessInfo.processInfo.systemUptime + 1, name: "test") {
            $0(42, nil)
        }
        XCTAssertEqual(value, 42)
        XCTAssertNil(call.pendingID)
    }

    func testTimeoutReturnsButDoesNotAllowRetryUntilRealCallback() async throws {
        let call = ComputerUseNativeCall()
        var callback: (@Sendable (Int?, Error?) -> Void)?
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let _: Int = try await call.run(deadline: start + 0.05, name: "test") { callback = $0 }
            XCTFail("A missing native callback must not silently pass")
        } catch {
            XCTAssertEqual((error as? ComputerUseFailure)?.code, "computer_test_timeout_delivery_unknown")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertNotNil(call.pendingID)
        var retryStarted = false
        do {
            let _: Int = try await call.run(deadline: start + 1, name: "retry") { _ in retryStarted = true }
            XCTFail("Do not accumulate native operations behind a timed-out call")
        } catch {
            XCTAssertEqual((error as? ComputerUseFailure)?.code, "computer_native_operation_still_pending")
        }
        XCTAssertFalse(retryStarted)
        callback?(99, nil)
        for _ in 0..<20 where call.pendingID != nil { await Task.yield() }
        XCTAssertNil(call.pendingID)
        let recovered: Int = try await call.run(deadline: start + 1, name: "fresh") { $0(7, nil) }
        XCTAssertEqual(recovered, 7)
    }

    func testDuplicateOldCallbackCannotClearNewNativeRequest() async throws {
        let call = ComputerUseNativeCall()
        var first: (@Sendable (Int?, Error?) -> Void)?
        let value: Int = try await call.run(deadline: ProcessInfo.processInfo.systemUptime + 1, name: "first") {
            first = $0
            $0(1, nil)
        }
        XCTAssertEqual(value, 1)
        var second: (@Sendable (Int?, Error?) -> Void)?
        let task = Task { @MainActor in
            let value: Int = try await call.run(deadline: ProcessInfo.processInfo.systemUptime + 1, name: "second") {
                second = $0
            }
            return value
        }
        for _ in 0..<20 where second == nil { await Task.yield() }
        let secondID = try XCTUnwrap(call.pendingID)
        first?(100, nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(call.pendingID, secondID)
        second?(2, nil)
        let result = try await task.value
        XCTAssertEqual(result, 2)
        XCTAssertNil(call.pendingID)
    }

    func testExpiredDeadlineNeverStartsFrameworkOperation() async throws {
        let call = ComputerUseNativeCall()
        var started = false
        do {
            let _: Int = try await call.run(deadline: 0, name: "expired") { _ in started = true }
            XCTFail("Expired request should fail before invoking a framework")
        } catch {}
        XCTAssertFalse(started)
        XCTAssertNil(call.pendingID)
    }
}
