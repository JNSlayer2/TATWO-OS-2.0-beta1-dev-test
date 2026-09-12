import Foundation
import Darwin
import ApplicationServices
import XCTest
@testable import Tatwo2

final class ComputerUseSessionTests: XCTestCase {
    func testLateActionCleanupCannotEndNewActionUnderSameGrant() throws {
        for lane: ComputerUseSession.Lane in [.externalApplication, .builtInBrowser] {
            let gate = ComputerUseSession()
            let value = try gate.authorize(owner: UUID(), scope: "same-chat", pid: getpid(),
                expectedEpoch: gate.currentEpoch, lane: lane)
            let old = try gate.publish(fingerprint: "state", for: value)
            try gate.beginAction(observationID: old.id.uuidString, fingerprint: "state", for: value)
            gate.endAction(observationID: old.id, for: value)
            let current = try gate.publish(fingerprint: "state", for: value)
            try gate.beginAction(observationID: current.id.uuidString, fingerprint: "state", for: value)

            gate.endAction(observationID: old.id, for: value)
            XCTAssertThrowsError(try gate.publish(fingerprint: "interleaving-read", for: value))
            var dispatched = false
            try gate.dispatch(observationID: current.id, for: value) { dispatched = true }
            XCTAssertTrue(dispatched)
            gate.endAction(observationID: current.id, for: value)
            XCTAssertNoThrow(try gate.publish(fingerprint: "after-current", for: value))
        }
    }

    func testLateActionDispatchCannotBorrowNewActionUnderSameGrant() throws {
        for lane: ComputerUseSession.Lane in [.externalApplication, .builtInBrowser] {
            let gate = ComputerUseSession()
            let value = try gate.authorize(owner: UUID(), scope: "same-chat", pid: getpid(),
                expectedEpoch: gate.currentEpoch, lane: lane)
            let old = try gate.publish(fingerprint: "state", for: value)
            try gate.beginAction(observationID: old.id.uuidString, fingerprint: "state", for: value)
            gate.endAction(observationID: old.id, for: value)
            let current = try gate.publish(fingerprint: "state", for: value)
            try gate.beginAction(observationID: current.id.uuidString, fingerprint: "state", for: value)
            var dispatched = 0
            XCTAssertThrowsError(try gate.dispatch(observationID: old.id, for: value) { dispatched += 1 })
            XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: old.id, for: value) {
                dispatched += 1
            })
            try gate.dispatch(observationID: current.id, for: value) { dispatched += 1 }
            XCTAssertEqual(dispatched, 1)
        }
    }

    func testObservedBrowserStagesRetainOneConsumedObservationUntilCleanup() throws {
        let gate = ComputerUseSession()
        let browser = try browserGrant(gate)
        let observed = try gate.publish(fingerprint: "surface|navigation|viewport|DOM", for: browser)
        try gate.beginAction(observationID: observed.id.uuidString,
            fingerprint: observed.fingerprint, for: browser)
        var stages: [String] = []
        XCTAssertEqual(try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) {
            stages.append("resolve")
            return "enqueued"
        }, "enqueued")
        XCTAssertThrowsError(try gate.dispatchBrowser(for: browser) { stages.append("navigation") })
        XCTAssertThrowsError(try gate.publish(fingerprint: "parallel-read", for: browser))
        try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) { stages.append("input") }
        gate.endAction(observationID: observed.id, for: browser)
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) {
            stages.append("late-stage")
        })
        XCTAssertEqual(stages, ["resolve", "input"])
        XCTAssertNoThrow(try gate.dispatchBrowser(for: browser) { "navigation-after-cleanup" })
    }

    func testObservedBrowserDispatchRequiresBeginAndRejectsReplayAfterCleanup() throws {
        let gate = ComputerUseSession()
        let browser = try browserGrant(gate)
        let observed = try gate.publish(fingerprint: "page", for: browser)
        var dispatched = 0
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) {
            dispatched += 1
        })
        try gate.beginAction(observationID: observed.id.uuidString, fingerprint: "page", for: browser)
        try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) { dispatched += 1 }
        gate.endAction(observationID: observed.id, for: browser)
        XCTAssertThrowsError(try gate.beginAction(observationID: observed.id.uuidString,
            fingerprint: "page", for: browser))
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) {
            dispatched += 1
        })
        XCTAssertEqual(dispatched, 1)
    }

    func testObservedBrowserDispatchRejectsExternalGrantWithoutEndingItsAction() throws {
        let gate = ComputerUseSession()
        let external = try grant(gate)
        let observed = try gate.publish(fingerprint: "document", for: external)
        try gate.beginAction(observationID: observed.id.uuidString, fingerprint: "document", for: external)
        var dispatched = 0
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: observed.id, for: external) {
            dispatched += 1
        })
        try gate.dispatch(observationID: observed.id, for: external) { dispatched += 1 }
        XCTAssertEqual(dispatched, 1)
    }

    func testObservedBrowserDispatchStopsAndCannotAffectReauthorizedAction() throws {
        let gate = ComputerUseSession()
        let oldGrant = try browserGrant(gate)
        let old = try gate.publish(fingerprint: "page", for: oldGrant)
        try gate.beginAction(observationID: old.id.uuidString, fingerprint: "page", for: oldGrant)
        gate.stop(owner: oldGrant.owner)
        var dispatched = 0
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: old.id, for: oldGrant) {
            dispatched += 1
        })
        let currentGrant = try gate.authorize(owner: oldGrant.owner, scope: oldGrant.scope, pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        let current = try gate.publish(fingerprint: "page", for: currentGrant)
        try gate.beginAction(observationID: current.id.uuidString, fingerprint: "page", for: currentGrant)
        gate.endAction(observationID: old.id, for: oldGrant)
        gate.endAction(observationID: current.id, for: oldGrant)
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: current.id, for: oldGrant) {
            dispatched += 1
        })
        try gate.dispatchObservedBrowser(observationID: current.id, for: currentGrant) { dispatched += 1 }
        XCTAssertEqual(dispatched, 1)
    }

    func testUnknownActionIDCannotDispatchOrClearCurrentAction() throws {
        let gate = ComputerUseSession()
        let browser = try browserGrant(gate)
        let observed = try gate.publish(fingerprint: "page", for: browser)
        try gate.beginAction(observationID: observed.id.uuidString, fingerprint: "page", for: browser)
        let unknown = UUID()
        gate.endAction(observationID: unknown, for: browser)
        var dispatched = 0
        XCTAssertThrowsError(try gate.dispatch(observationID: unknown, for: browser) { dispatched += 1 })
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: unknown, for: browser) {
            dispatched += 1
        })
        XCTAssertThrowsError(try gate.dispatchBrowser(for: browser) { dispatched += 1 })
        try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) { dispatched += 1 }
        XCTAssertEqual(dispatched, 1)
    }

    func testUncertainObservedBrowserDeliveryNeverRestoresConsumedObservation() throws {
        let gate = ComputerUseSession()
        let browser = try browserGrant(gate)
        let observed = try gate.publish(fingerprint: "page", for: browser)
        try gate.beginAction(observationID: observed.id.uuidString, fingerprint: "page", for: browser)
        var attempted = 0
        XCTAssertThrowsError(try gate.dispatchObservedBrowser(observationID: observed.id, for: browser) {
            attempted += 1
            throw ComputerUseFailure("delivery_unknown")
        })
        XCTAssertThrowsError(try gate.publish(fingerprint: "parallel-read", for: browser))
        gate.endAction(observationID: observed.id, for: browser)
        XCTAssertThrowsError(try gate.beginAction(observationID: observed.id.uuidString,
            fingerprint: "page", for: browser))
        XCTAssertEqual(attempted, 1)
        XCTAssertNoThrow(try gate.publish(fingerprint: "inspect-after-uncertain-delivery", for: browser))
    }

    func testKnownStaleObservationCannotReviveWhenContentReturns() throws {
        let gate = ComputerUseSession()
        let value = try browserGrant(gate)
        let old = try gate.publish(fingerprint: "original", for: value)
        XCTAssertThrowsError(try gate.beginAction(observationID: old.id.uuidString,
            fingerprint: "changed", for: value))
        XCTAssertThrowsError(try gate.beginAction(observationID: old.id.uuidString,
            fingerprint: "original", for: value))
        let fresh = try gate.publish(fingerprint: "original", for: value)
        XCTAssertNoThrow(try gate.beginAction(observationID: fresh.id.uuidString,
            fingerprint: "original", for: value))
    }

    func testWrongObservationTokenCannotDiscardCurrentObservation() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        let current = try gate.publish(fingerprint: "state", for: value)
        for wrong in ["", "not-an-observation", UUID().uuidString] {
            XCTAssertThrowsError(try gate.beginAction(observationID: wrong,
                fingerprint: "different", for: value))
        }
        XCTAssertNoThrow(try gate.beginAction(observationID: current.id.uuidString,
            fingerprint: "state", for: value))
    }

    func testBrowserAndExternalAppsShareOneInputOwner() throws {
        let gate = ComputerUseSession()
        let external = try grant(gate)
        XCTAssertEqual(external.lane, .externalApplication)
        XCTAssertThrowsError(try gate.authorize(owner: external.owner, scope: external.scope,
            pid: getpid(), expectedEpoch: gate.currentEpoch, lane: .builtInBrowser))
        gate.stop(owner: external.owner)
        let browser = try gate.authorize(owner: external.owner, scope: external.scope,
            pid: getpid(), expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        XCTAssertThrowsError(try grant(gate, owner: external.owner))
        XCTAssertEqual(try gate.require(owner: browser.owner, scope: browser.scope,
            token: browser.id.uuidString, lane: .builtInBrowser), browser)
    }

    func testBrowserTokenCannotBePresentedToExternalAppLane() throws {
        let gate = ComputerUseSession()
        let browser = try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        XCTAssertThrowsError(try gate.require(owner: browser.owner, scope: browser.scope,
            token: browser.id.uuidString))
        XCTAssertThrowsError(try gate.require(owner: UUID(), scope: browser.scope,
            token: browser.id.uuidString, lane: .builtInBrowser))
        XCTAssertThrowsError(try gate.require(owner: browser.owner, scope: "other-space",
            token: browser.id.uuidString, lane: .builtInBrowser))
    }

    func testExternalTokenCannotDispatchBrowserCommands() throws {
        let gate = ComputerUseSession()
        let external = try grant(gate)
        var dispatched = 0
        XCTAssertThrowsError(try gate.require(owner: external.owner, scope: external.scope,
            token: external.id.uuidString, lane: .builtInBrowser))
        XCTAssertThrowsError(try gate.dispatchBrowser(for: external) { dispatched += 1 })
        XCTAssertEqual(dispatched, 0)
    }

    func testBrowserStopBlocksTheNextDispatchAndOldTokenAfterRestore() throws {
        let gate = ComputerUseSession()
        let old = try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        var dispatched = 0
        XCTAssertEqual(try gate.dispatchBrowser(for: old) { dispatched += 1; return "enqueued" }, "enqueued")
        gate.stop(owner: old.owner)
        XCTAssertThrowsError(try gate.dispatchBrowser(for: old) { dispatched += 1 })
        let new = try gate.authorize(owner: old.owner, scope: old.scope, pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        XCTAssertThrowsError(try gate.require(owner: old.owner, scope: old.scope,
            token: old.id.uuidString, lane: .builtInBrowser))
        gate.stop(ifCurrent: old)
        try gate.dispatchBrowser(for: new) { dispatched += 1 }
        XCTAssertEqual(dispatched, 2)
    }

    func testBrowserCommandCannotInterleaveWithConsumedNativeGesture() throws {
        let gate = ComputerUseSession()
        let browser = try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        let observed = try gate.publish(fingerprint: "browser-view", for: browser, imageWidth: 800, imageHeight: 600)
        try gate.beginAction(observationID: observed.id.uuidString, fingerprint: "browser-view", for: browser)
        var dispatched = 0
        XCTAssertThrowsError(try gate.dispatchBrowser(for: browser) { dispatched += 1 })
        try gate.dispatch(observationID: observed.id, for: browser) { dispatched += 1 }
        gate.endAction(observationID: observed.id, for: browser)
        try gate.dispatchBrowser(for: browser) { dispatched += 1 }
        XCTAssertEqual(dispatched, 2)
    }

    func testBrowserGrantStillExpiresWithoutExtendingItsLease() throws {
        let gate = ComputerUseSession()
        let browser = try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser, now: 100)
        XCTAssertNoThrow(try gate.require(owner: browser.owner, scope: browser.scope,
            token: browser.id.uuidString, lane: .builtInBrowser, now: 999.999))
        XCTAssertThrowsError(try gate.require(owner: browser.owner, scope: browser.scope,
            token: browser.id.uuidString, lane: .builtInBrowser, now: 1000))
    }

    func testBrowserEnqueueInvalidatesEarlierNativeObservation() throws {
        let gate = ComputerUseSession()
        let browser = try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        let old = try gate.publish(fingerprint: "same-page", for: browser)
        var dispatched = false
        try gate.dispatchBrowser(for: browser) { dispatched = true }
        XCTAssertTrue(dispatched)
        XCTAssertThrowsError(try gate.beginAction(observationID: old.id.uuidString,
            fingerprint: "same-page", for: browser))
        let fresh = try gate.publish(fingerprint: "same-page", for: browser)
        XCTAssertNoThrow(try gate.beginAction(observationID: fresh.id.uuidString,
            fingerprint: "same-page", for: browser))
        gate.endAction(observationID: fresh.id, for: browser)
    }

    func testUncertainBrowserEnqueueDoesNotRestoreEarlierObservation() throws {
        let gate = ComputerUseSession()
        let browser = try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
        let old = try gate.publish(fingerprint: "same-page", for: browser)
        XCTAssertThrowsError(try gate.dispatchBrowser(for: browser) {
            throw ComputerUseFailure("delivery_unknown")
        })
        XCTAssertThrowsError(try gate.beginAction(observationID: old.id.uuidString,
            fingerprint: "same-page", for: browser))
    }

    func testRejectedOtherLaneEnqueueCannotInvalidateCurrentObservation() throws {
        let gate = ComputerUseSession()
        let external = try grant(gate)
        let old = try gate.publish(fingerprint: "document", for: external)
        var dispatched = false
        XCTAssertThrowsError(try gate.dispatchBrowser(for: external) { dispatched = true })
        XCTAssertFalse(dispatched)
        XCTAssertNoThrow(try gate.beginAction(observationID: old.id.uuidString,
            fingerprint: "document", for: external))
        gate.endAction(observationID: old.id, for: external)
    }

    func testCaptureGeometryBelongsToTheConsumedObservation() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        let first = try gate.publish(fingerprint: "state", for: value, imageWidth: 1600, imageHeight: 900)
        let current = try gate.publish(fingerprint: "state", for: value, imageWidth: 800, imageHeight: 450)
        XCTAssertThrowsError(try gate.beginAction(observationID: first.id.uuidString, fingerprint: "state", for: value))
        let consumed = try gate.beginAction(observationID: current.id.uuidString, fingerprint: "state", for: value)
        XCTAssertEqual(consumed.imageWidth, 800)
        XCTAssertEqual(consumed.imageHeight, 450)
        gate.endAction(observationID: consumed.id, for: value)
        XCTAssertThrowsError(try gate.beginAction(observationID: current.id.uuidString, fingerprint: "state", for: value))
    }

    func testMalformedCaptureGeometryCannotPublish() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        for (width, height) in [(-1, 100), (0, 100), (100, 0), (2049, 100), (100, 2049)] {
            XCTAssertThrowsError(try gate.publish(fingerprint: "state", for: value, imageWidth: width, imageHeight: height))
        }
        let windowless = try gate.publish(fingerprint: "none", for: value)
        XCTAssertEqual(windowless.imageWidth, 0)
        XCTAssertEqual(windowless.imageHeight, 0)
    }

    func testDarwinHalfCloseIsNotAFullDisconnect() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            for fd in sockets where fd >= 0 { close(fd) }
        }
        XCTAssertTrue(ComputerUseConnection.isAlive(sockets[0]))
        XCTAssertEqual(shutdown(sockets[1], SHUT_WR), 0)
        XCTAssertTrue(ComputerUseConnection.isAlive(sockets[0]), "MCP normally half-closes its request stream.")
        close(sockets[1])
        sockets[1] = -1
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ComputerUseConnection.isAlive(sockets[0]), ProcessInfo.processInfo.systemUptime < deadline {
            usleep(1_000)
        }
        XCTAssertFalse(ComputerUseConnection.isAlive(sockets[0]), "Late native approval must reject a disconnected receiver.")
    }
    private func grant(_ gate: ComputerUseSession, owner: UUID = UUID()) throws -> ComputerUseSession.Grant {
        try gate.authorize(owner: owner, scope: "local-chat", pid: 123,
                           expectedEpoch: gate.currentEpoch)
    }

    private func browserGrant(_ gate: ComputerUseSession) throws -> ComputerUseSession.Grant {
        try gate.authorize(owner: UUID(), scope: "browser-chat", pid: getpid(),
            expectedEpoch: gate.currentEpoch, lane: .builtInBrowser)
    }

    func testCallerAndSpaceMustBothMatch() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        XCTAssertEqual(try gate.require(owner: value.owner, scope: value.scope, token: value.id.uuidString), value)
        XCTAssertThrowsError(try gate.require(owner: UUID(), scope: value.scope, token: value.id.uuidString))
        XCTAssertThrowsError(try gate.require(owner: value.owner, scope: "other-space", token: value.id.uuidString))
        XCTAssertThrowsError(try gate.require(owner: value.owner, scope: value.scope, token: UUID().uuidString))
    }

    func testPendingConsentCannotAuthorizeAfterStop() throws {
        let gate = ComputerUseSession()
        let epoch = gate.currentEpoch
        gate.stop()
        XCTAssertThrowsError(try gate.authorize(owner: UUID(), scope: "local-chat", pid: 123, expectedEpoch: epoch))
    }

    func testObservationIsSingleUseAndCannotPublishDuringInput() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        let observation = try gate.publish(fingerprint: "real-state", for: value)
        try gate.beginAction(observationID: observation.id.uuidString, fingerprint: "real-state", for: value)
        XCTAssertThrowsError(try gate.publish(fingerprint: "parallel-read", for: value))
        gate.endAction(observationID: observation.id, for: value)
        XCTAssertThrowsError(try gate.beginAction(observationID: observation.id.uuidString, fingerprint: "real-state", for: value))
    }

    func testMovedWindowOrChangedContentRequiresNewObservation() throws {
        let gate = ComputerUseSession()
        let value = try browserGrant(gate)
        let observation = try gate.publish(fingerprint: "original", for: value)
        XCTAssertThrowsError(try gate.beginAction(observationID: observation.id.uuidString, fingerprint: "changed", for: value))
    }

    func testOldObservationsAndExpiredConsentAreRejected() throws {
        let gate = ComputerUseSession()
        let value = try browserGrant(gate)
        let now = ProcessInfo.processInfo.systemUptime
        let observation = try gate.publish(fingerprint: "state", for: value, now: now)
        XCTAssertThrowsError(try gate.beginAction(observationID: observation.id.uuidString, fingerprint: "state", for: value, now: now + 31))
        XCTAssertThrowsError(try gate.require(owner: value.owner, scope: value.scope, token: value.id.uuidString, now: now + 901))
    }

    func testStopImmediatelyBlocksDispatchAndLateCapture() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        let observation = try gate.publish(fingerprint: "state", for: value)
        try gate.beginAction(observationID: observation.id.uuidString, fingerprint: "state", for: value)
        var count = 0
        try gate.dispatch(observationID: observation.id, for: value) { count += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        gate.stop(owner: value.owner)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertThrowsError(try gate.dispatch(observationID: observation.id, for: value) { count += 1 })
        XCTAssertThrowsError(try gate.publish(fingerprint: "late-capture", for: value))
        XCTAssertEqual(count, 1)
    }

    func testOldGrantCannotActAfterExplicitReauthorization() throws {
        let gate = ComputerUseSession()
        let old = try grant(gate)
        gate.stop()
        let new = try grant(gate, owner: old.owner)
        XCTAssertNotEqual(new.id, old.id)
        gate.stop(ifCurrent: old)
        XCTAssertNoThrow(try gate.validate(new), "Late cleanup must not revoke a newer grant for the same owner.")
        XCTAssertThrowsError(try gate.publish(fingerprint: "late", for: old))
        XCTAssertNoThrow(try gate.publish(fingerprint: "new", for: new))
    }

    func testOnlyOneOwnerAndAnotherThreadCannotRevokeIt() throws {
        let gate = ComputerUseSession()
        let value = try grant(gate)
        XCTAssertThrowsError(try grant(gate))
        gate.stop(owner: UUID())
        XCTAssertNoThrow(try gate.validate(value))
        gate.stop(owner: value.owner)
        XCTAssertThrowsError(try gate.validate(value))
    }
    func testExternalLatestIDIgnoresContentChangesAndAgeWithinLease() throws {
        let gate = ComputerUseSession()
        let grant = try grant(gate)
        let now = ProcessInfo.processInfo.systemUptime
        let first = try gate.publish(fingerprint: "clock:1", for: grant, now: now)
        let latest = try gate.publish(fingerprint: "clock:2", for: grant, now: now)
        XCTAssertThrowsError(try gate.beginAction(observationID: first.id.uuidString, fingerprint: "clock:3", for: grant)) {
            XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_stale_observation")
        }
        XCTAssertNoThrow(try gate.beginAction(observationID: latest.id.uuidString,
            fingerprint: "clock:changed", for: grant, now: now + 60))
    }

    func testObservationOwnsElementArrayAndRejectsOutOfBounds() throws {
        let gate = ComputerUseSession()
        let grant = try grant(gate)
        let node = AXUIElementCreateApplication(getpid()) // no AX lookup or GUI operation
        let observed = try gate.publish(fingerprint: "", for: grant, elements: [node])
        XCTAssertTrue(CFEqual(try observed.element(at: 0), node))
        for index in [-1, 1, 600, Int.max] {
            XCTAssertThrowsError(try observed.element(at: index)) {
                XCTAssertEqual(($0 as? ComputerUseFailure)?.code, "computer_element_stale")
            }
        }
        gate.stop()
        XCTAssertThrowsError(try gate.beginAction(observationID: observed.id.uuidString, fingerprint: "", for: grant))
    }

    func testConsentReuseIsBoundToOwnerScopeEpochAndExpiry() throws {
        let gate = ComputerUseSession()
        let owner = UUID()
        let first = try gate.authorize(owner: owner, scope: "chat", pid: 123, expectedEpoch: gate.currentEpoch, now: 100)
        var cache = ComputerUseConsentCache(owner: owner, scope: "chat", epoch: first.epoch, expiresAt: first.expiresAt)
        cache.apps.insert("app.A")
        XCTAssertTrue(cache.permits("app.A", owner: owner, scope: "chat", epoch: gate.currentEpoch, now: 200))
        XCTAssertFalse(cache.permits("app.B", owner: owner, scope: "chat", epoch: gate.currentEpoch, now: 200))
        // Internal target switch uses the existing epoch architecture and the original expiry.
        gate.stop()
        let second = try gate.authorize(owner: owner, scope: "chat", pid: 124, expectedEpoch: gate.currentEpoch,
                                        expiresAt: cache.expiresAt, now: 200)
        cache.epoch = second.epoch
        cache.apps.insert("app.B")
        XCTAssertEqual(second.expiresAt, first.expiresAt)
        XCTAssertTrue(cache.permits("app.A", owner: owner, scope: "chat", epoch: gate.currentEpoch, now: 300))
        XCTAssertFalse(cache.permits("app.A", owner: UUID(), scope: "chat", epoch: gate.currentEpoch, now: 300))
        XCTAssertFalse(cache.permits("app.A", owner: owner, scope: "other", epoch: gate.currentEpoch, now: 300))
        XCTAssertFalse(cache.permits("app.A", owner: owner, scope: "chat", epoch: gate.currentEpoch, now: 1000))
        gate.stop()
        XCTAssertFalse(cache.permits("app.A", owner: owner, scope: "chat", epoch: gate.currentEpoch, now: 300))
    }

}
