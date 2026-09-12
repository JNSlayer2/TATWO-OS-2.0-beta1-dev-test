import Darwin
import Foundation
import TatwoUltraworkCore
import XCTest

@testable import TatwoUltraworkMac

final class ChatRunnerAuthorityDurabilityTests: XCTestCase {
    func testRunnerUsesClaimedIdentityAndRecordsFormalTerminal() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let runner = ChatCLIProcessRunner(
            outputPollPolicy: ChatCLIOutputPollPolicy(
                initialDelay: 0.01,
                repeatInterval: 0.01),
            runnerAuthority: authority)
        let terminal = expectation(description: "formal terminal")
        let runID = "runner-wiring-\(UUID().uuidString)"
        let identity = runner.start(
            command: ChatCLICommand(
                engine: .codex,
                executable: "/bin/sh",
                arguments: ["-c", "printf runner-authority-ok"],
                workingDirectory: FileManager.default.temporaryDirectory,
                expectsJSON: false,
                capturesSessionID: false,
                standardInputFromDevNull: true,
                requiresForegroundScheduling: false,
                runtimeAdapter: .gatewayDirect,
                commandMode: .chat),
            runID: runID
        ) { event in
            if case .exit = event {
                terminal.fulfill()
            }
        }

        XCTAssertNotNil(identity)
        XCTAssertEqual(
            runner.diagnosticsSnapshot.authorityIdentity,
            identity)
        wait(for: [terminal], timeout: 3)
        guard let identity else {
            return XCTFail("runner did not return claimed identity")
        }
        XCTAssertEqual(
            authority.discoverRunnerAuthority(),
            .authoritative(
                activeRunIDs: [],
                reclaimTokens: [ChatRunnerReclaimToken(
                    runID: identity.runID,
                    attempt: identity.attempt,
                    instanceID: identity.instanceID,
                    revision: identity.revision)]))
    }

    func testFreshAuthorityDiscoversLiveRunnerAndExactTerminalReclaim() throws {
        let root = temporaryAuthorityRoot()
        let first = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let identity = try first.claim(
            runID: "relaunch-live-\(UUID().uuidString)",
            attempt: 1)
        try first.attach(
            identity: identity,
            launch: try launchIdentity(for: process))

        let relaunched = ChatDurableRunnerAuthority(rootURL: root)
        XCTAssertEqual(
            relaunched.discoverRunnerAuthority(),
            .authoritative(
                activeRunIDs: [identity.runID],
                reclaimTokens: []))

        XCTAssertEqual(
            first.recordRunTerminal(identity: identity, status: 0),
            .persisted)
        process.terminate()
        process.waitUntilExit()

        XCTAssertEqual(
            relaunched.discoverRunnerAuthority(),
            .authoritative(
                activeRunIDs: [],
                reclaimTokens: [ChatRunnerReclaimToken(
                    runID: identity.runID,
                    attempt: identity.attempt,
                    instanceID: identity.instanceID,
                    revision: identity.revision)]))
    }

    func testRelaunchedStopRequestsTerminationThenDiscoversExactReclaim() throws {
        let root = temporaryAuthorityRoot()
        let original = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let identity = try original.claim(
            runID: "relaunch-stop-\(UUID().uuidString)",
            attempt: 1)
        try original.attach(
            identity: identity,
            launch: try launchIdentity(for: process))

        let relaunched = ChatDurableRunnerAuthority(rootURL: root)
        XCTAssertEqual(
            relaunched.requestTermination(for: identity),
            .requested)
        process.waitUntilExit()

        let afterTermination = ChatDurableRunnerAuthority(rootURL: root)
        XCTAssertEqual(
            afterTermination.discoverRunnerAuthority(),
            .authoritative(
                activeRunIDs: [],
                reclaimTokens: [ChatRunnerReclaimToken(
                    runID: identity.runID,
                    attempt: identity.attempt,
                    instanceID: identity.instanceID,
                    revision: identity.revision)]))
        XCTAssertEqual(
            afterTermination.requestTermination(for: identity),
            .reclaimed(ChatRunnerReclaimToken(
                runID: identity.runID,
                attempt: identity.attempt,
                instanceID: identity.instanceID,
                revision: identity.revision)))
    }

    func testRolloverBlocksWhilePriorChildIsStillActive() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let runID = "bridge-attempt-\(UUID().uuidString)"
        let attemptOne = try authority.claim(runID: runID, attempt: 1)
        try authority.attach(
            identity: attemptOne,
            launch: try launchIdentity(for: process))
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: attemptOne, status: 0),
            .persisted)

        XCTAssertThrowsError(
            try authority.claim(
                runID: runID,
                attempt: 2,
                expectedPrior: rolloverExpectation(attemptOne, status: 0))
        ) { error in
            XCTAssertEqual(
                error as? ChatDurableRunnerAuthorityError,
                .claimBlocked(reason: "runner-prior-process-still-active"))
        }
        XCTAssertEqual(
            authority.discoverRunnerAuthority(),
            .authoritative(activeRunIDs: [runID], reclaimTokens: []),
            "blocked rollover must preserve the exact live child generation")
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: attemptOne, status: 0),
            .idempotent,
            "a blocked rollover must not mutate the prior generation")
    }

    func testRolloverBlocksWhenPriorLivenessIsUnknown() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let runID = "bridge-unknown-\(UUID().uuidString)"
        let attemptOne = try authority.claim(runID: runID, attempt: 1)
        try authority.attach(
            identity: attemptOne,
            launch: try launchIdentity(for: process))
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: attemptOne, status: 0),
            .persisted)
        try removeRunnerStartToken(fromSoleRecordAt: root)

        XCTAssertThrowsError(
            try authority.claim(
                runID: runID,
                attempt: 2,
                expectedPrior: rolloverExpectation(attemptOne, status: 0))
        ) { error in
            XCTAssertEqual(
                error as? ChatDurableRunnerAuthorityError,
                .claimBlocked(
                    reason:
                        "runner-prior-process-unknown:runner-process-identity-missing"))
        }
        XCTAssertEqual(
            authority.discoverRunnerAuthority(),
            .unknown(reason: "runner-process-identity-missing:\(runID)"),
            "unknown liveness must remain fail-closed after the rejected claim")
    }

    func testRolloverBlocksStaleExpectedIdentityWithoutMutation() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let runID = "bridge-stale-expectation-\(UUID().uuidString)"
        let attemptOne = try authority.claim(runID: runID, attempt: 1)
        try authority.attach(
            identity: attemptOne,
            launch: try launchIdentity(for: process))
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: attemptOne, status: 0),
            .persisted)
        let staleIdentity = ChatRunnerAttemptIdentity(
            runID: runID,
            attempt: attemptOne.attempt,
            instanceID: UUID(),
            revision: attemptOne.revision)

        XCTAssertThrowsError(
            try authority.claim(
                runID: runID,
                attempt: 2,
                expectedPrior: rolloverExpectation(staleIdentity, status: 0))
        ) { error in
            XCTAssertEqual(
                error as? ChatDurableRunnerAuthorityError,
                .claimBlocked(reason: "runner-stale-expected-prior-identity"))
        }

        let attemptTwo = try authority.claim(
            runID: runID,
            attempt: 2,
            expectedPrior: rolloverExpectation(attemptOne, status: 0))
        XCTAssertEqual(attemptTwo.revision, attemptOne.revision + 1)
    }

    func testAttemptTerminalAndInactivePriorAllowsExactRollover() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let runID = "bridge-valid-rollover-\(UUID().uuidString)"
        let attemptOne = try authority.claim(runID: runID, attempt: 1)
        try authority.attach(
            identity: attemptOne,
            launch: try launchIdentity(for: process))
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: attemptOne, status: 17),
            .persisted)

        let attemptTwo = try authority.claim(
            runID: runID,
            attempt: 2,
            expectedPrior: rolloverExpectation(attemptOne, status: 17))

        XCTAssertEqual(attemptTwo.runID, attemptOne.runID)
        XCTAssertEqual(attemptTwo.attempt, 2)
        XCTAssertNotEqual(attemptTwo.instanceID, attemptOne.instanceID)
        XCTAssertEqual(attemptTwo.revision, attemptOne.revision + 1)
        XCTAssertEqual(
            authority.recordRunTerminal(identity: attemptOne, status: 0),
            .blocked(reason: "runner-generation-mismatch"),
            "the old generation cannot terminate the new logical owner")
    }

    func testConcurrentRolloverClaimUsesRegistryCAS() throws {
        let root = temporaryAuthorityRoot()
        let original = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let runID = "bridge-concurrent-rollover-\(UUID().uuidString)"
        let attemptOne = try original.claim(runID: runID, attempt: 1)
        try original.attach(
            identity: attemptOne,
            launch: try launchIdentity(for: process))
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(
            original.recordAttemptTerminal(identity: attemptOne, status: 0),
            .persisted)

        let results = ConcurrentClaimResults()
        let group = DispatchGroup()
        let expectation = rolloverExpectation(attemptOne, status: 0)
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let authority = ChatDurableRunnerAuthority(rootURL: root)
                    results.record(success: try authority.claim(
                        runID: runID,
                        attempt: 2,
                        expectedPrior: expectation))
                } catch {
                    results.record(error: error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)

        XCTAssertEqual(results.successes.count, 1)
        XCTAssertEqual(results.errors.count, 1)
        XCTAssertEqual(results.successes.first?.attempt, 2)
        guard let losingError =
                results.errors.first as? ChatDurableRunnerAuthorityError,
              case .claimBlocked(reason: _) = losingError
        else {
            return XCTFail("losing concurrent claimant must fail closed")
        }
    }

    func testBridgeAttemptTerminalDoesNotBecomeRunTerminalOrReclaim() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let process = try startSleepProcess()
        let runID = "bridge-attempt-terminal-\(UUID().uuidString)"
        let identity = try authority.claim(runID: runID, attempt: 1)
        try authority.attach(
            identity: identity,
            launch: try launchIdentity(for: process))

        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: identity, status: 0),
            .persisted)
        XCTAssertEqual(
            authority.recordAttemptTerminal(identity: identity, status: 0),
            .idempotent)
        XCTAssertEqual(
            authority.discoverRunnerAuthority(),
            .unknown(
                reason:
                    "bridge-attempt-terminal-without-run-terminal:\(runID)"))
        XCTAssertEqual(
            authority.requestTermination(for: identity),
            .blocked(
                reason: "bridge-attempt-terminal-without-run-terminal"))
    }

    func testRunTerminalSameStatusIsIdempotentButConflictBlocks() throws {
        let root = temporaryAuthorityRoot()
        let authority = ChatDurableRunnerAuthority(rootURL: root)
        let identity = try authority.claim(
            runID: "terminal-idempotency-\(UUID().uuidString)",
            attempt: 1)

        XCTAssertEqual(
            authority.recordRunTerminal(identity: identity, status: -1),
            .persisted)
        XCTAssertEqual(
            authority.recordRunTerminal(identity: identity, status: -1),
            .idempotent)
        XCTAssertEqual(
            authority.recordRunTerminal(identity: identity, status: 0),
            .blocked(reason: "runner-terminal-conflict"))
    }

    func testCorruptRegistryFailsClosedInsteadOfReturningEmptyAuthority() throws {
        let root = temporaryAuthorityRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("corrupt.json"))

        XCTAssertEqual(
            ChatDurableRunnerAuthority(rootURL: root)
                .discoverRunnerAuthority(),
            .unknown(reason: "runner-registry-unreadable"))
    }

    private func temporaryAuthorityRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-runner-authority-tests-\(UUID().uuidString)",
                isDirectory: true)
    }

    private func startSleepProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func launchIdentity(
        for process: Process
    ) throws -> ChatRunnerLaunchIdentity {
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN))
        let length = proc_pidpath(
            process.processIdentifier,
            &buffer,
            UInt32(buffer.count))
        guard length > 0 else {
            throw ChatDurableRunnerAuthorityError.processIdentityUnavailable
        }
        return ChatRunnerLaunchIdentity(
            pid: process.processIdentifier,
            executablePath: String(cString: buffer),
            argvDigest: "test-sleep-30",
            launchShape: "process",
            launchctlLabel: nil,
            uid: getuid())
    }

    private func rolloverExpectation(
        _ identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerClaimRolloverExpectation {
        ChatRunnerClaimRolloverExpectation(
            identity: identity,
            phase: .attemptTerminal(status: status))
    }

    private func removeRunnerStartToken(
        fromSoleRecordAt root: URL
    ) throws {
        let records = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let recordURL = try XCTUnwrap(records.only)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: recordURL)) as? [String: Any])
        object["runnerStartToken"] = NSNull()
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: recordURL, options: .atomic)
    }
}

private final class ConcurrentClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successes: [ChatRunnerAttemptIdentity] = []
    private(set) var errors: [Error] = []

    func record(success: ChatRunnerAttemptIdentity) {
        lock.lock()
        successes.append(success)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
