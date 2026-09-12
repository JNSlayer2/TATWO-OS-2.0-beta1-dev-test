import Foundation
import XCTest

@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class TatwoMacPressureRuntimeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_786_444_000.0)

    func testMacSensorProviderUnavailableDataVolumeFailsClosedAsUnknown() async throws {
        let provider = TatwoMacPressureSensorProviderV1.isolatedForTests(
            dataVolumeURL: URL(fileURLWithPath: "/tmp/tatwo-definitely-missing-pressure-volume", isDirectory: true),
            timeoutSeconds: 1.0
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let readings = await provider.sampleWithTimeout(context: context)
        let snapshot = readings.snapshot(
            deviceID: "mini-A",
            observedAt: base,
            activeLoopID: nil,
            workers: []
        )
        let classification = snapshot.classify(now: base)

        XCTAssertEqual(classification.classification, .unknown)
        XCTAssertTrue(classification.reasonCodes.contains("sensor_unavailable:data_volume_free_gib"))
    }

    func testMacSensorProviderTimeoutReturnsUnknownWithoutWaitingForSlowProbe() async throws {
        let provider = TatwoMacPressureSensorProviderV1.isolatedForTests(
            timeoutSeconds: 0.2,
            sampleOverride: { _ in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return TatwoDevicePressureSensorReadingsV1(
                    memoryFreePercent: 40,
                    swapFreeMiB: 2_048,
                    dataVolumeFreeGiB: 40,
                    load1PerCPU: 0.2,
                    thermalWarning: false,
                    uiLatencyMilliseconds: 20,
                    swapGrowthMiBPerMinute: 0)
            }
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let started = Date()
        let readings = await provider.sampleWithTimeout(context: context)
        let elapsed = Date().timeIntervalSince(started)
        let snapshot = readings.snapshot(
            deviceID: "mini-A",
            observedAt: base,
            activeLoopID: nil,
            workers: []
        )

        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(snapshot.classify(now: base).classification, .unknown)
        XCTAssertTrue(
            readings.unavailableSensors.allSatisfy { $0.reasonCode == "sensor_timeout" })
    }

    func testMacSensorProviderFirstSwapGrowthSampleRequiresBaseline() async throws {
        let provider = TatwoMacPressureSensorProviderV1.isolatedForTests(
            dataVolumeURL: URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true),
            timeoutSeconds: 2.0
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let readings = await provider.sampleWithTimeout(context: context)
        let snapshot = readings.snapshot(
            deviceID: "mini-A",
            observedAt: base,
            activeLoopID: nil,
            workers: []
        )

        XCTAssertTrue(readings.unavailableSensors.contains {
            $0.sensor == .swapGrowthMiBPerMinute
                && $0.reasonCode == "swap_growth_baseline_missing"
        })
        XCTAssertEqual(snapshot.classify(now: base).classification, .unknown)
    }

    @MainActor
    func testAppPressureRuntimeRegistryPublishesAndClearsAppOwnedRuntime() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let sampler = TatwoAppPressureSamplerV1(
            deviceID: "mini-A",
            provider: TatwoDevicePressureSensorProviderV1 { _ in
                TatwoDevicePressureSensorReadingsV1(
                    memoryFreePercent: 40,
                    swapFreeMiB: 2_048,
                    dataVolumeFreeGiB: 40,
                    load1PerCPU: 0.2,
                    thermalWarning: false,
                    uiLatencyMilliseconds: 20,
                    swapGrowthMiBPerMinute: 0)
            }
        )
        let runtime = TatwoAppPressureRuntimeV1(sampler: sampler)

        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        XCTAssertNotNil(TatwoAppPressureRuntimeRegistry.runtime)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.isCurrent(runtime, generation: generation))
        await runtime.start(reason: .test, startTimers: false)
        let lease = await runtime.currentLease()
        XCTAssertNotNil(lease)
        await runtime.stop(reason: .appDidSuspend)
        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.runtime)
    }

    @MainActor
    func testAppPressureRuntimeRegistryIgnoresStaleClearAndKeepsNewestRuntime() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let first = TatwoAppPressureRuntimeV1(sampler: makeGreenSampler(deviceID: "mini-A"))
        let second = TatwoAppPressureRuntimeV1(sampler: makeGreenSampler(deviceID: "mini-A"))

        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(first)
        let secondGeneration = TatwoAppPressureRuntimeRegistry.install(second)

        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.isCurrent(first, generation: firstGeneration))
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.isCurrent(second, generation: secondGeneration))
        TatwoAppPressureRuntimeRegistry.clear(generation: firstGeneration)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.isCurrent(second, generation: secondGeneration))
        TatwoAppPressureRuntimeRegistry.clear(generation: secondGeneration)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.runtime)
    }

    func testAppProcessOwnedProvidersShareTimedOperationCapAcrossInstances() async throws {
        let blocker = BlockingMacPressureOverride()
        let firstProvider = TatwoMacPressureSensorProviderV1.appProcessOwned(
            timeoutSeconds: 0.2,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let secondProvider = TatwoMacPressureSensorProviderV1.appProcessOwned(
            timeoutSeconds: 0.2,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let first = await firstProvider.sampleWithTimeout(context: context)
        XCTAssertTrue(first.unavailableSensors.allSatisfy { $0.reasonCode == "sensor_timeout" })
        let countAfterFirst = await blocker.count()
        let firstActiveAfterFirst = await firstProvider.activeTimedOperationCountForTest()
        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(firstActiveAfterFirst, 1)

        let second = await secondProvider.sampleWithTimeout(context: context)
        XCTAssertTrue(second.unavailableSensors.allSatisfy {
            $0.reasonCode == "sensor_timeout_inflight_limit"
        })
        let countAfterSecond = await blocker.count()
        let secondActiveAfterSecond = await secondProvider.activeTimedOperationCountForTest()
        XCTAssertEqual(countAfterSecond, 1)
        XCTAssertEqual(secondActiveAfterSecond, 1)

        await blocker.releaseAll()
        try await waitUntil {
            await blocker.completedCount() == 1
        }
        try await waitUntil {
            let firstActive = await firstProvider.activeTimedOperationCountForTest()
            let secondActive = await secondProvider.activeTimedOperationCountForTest()
            return firstActive == 0 && secondActive == 0
        }
    }

    func testAppProcessOwnedProviderRestartSharesOnePhysicalTimedOperationOwner() async throws {
        let blocker = BlockingMacPressureOverride()
        let firstProvider = TatwoMacPressureSensorProviderV1.appProcessOwned(
            timeoutSeconds: 0.2,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let restartedProvider = TatwoMacPressureSensorProviderV1.appProcessOwned(
            timeoutSeconds: 0.2,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let laterProvider = TatwoMacPressureSensorProviderV1.appProcessOwned(
            timeoutSeconds: 0.2,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let firstOwnerID = await firstProvider.timedOperationOwnerIdentityForTest()
        let restartedOwnerID = await restartedProvider.timedOperationOwnerIdentityForTest()
        let laterOwnerID = await laterProvider.timedOperationOwnerIdentityForTest()
        XCTAssertEqual(
            firstOwnerID,
            restartedOwnerID,
            "appProcessOwned() must reuse one process-wide timed-operation owner, not manufacture a fresh owner per provider.")
        XCTAssertEqual(
            restartedOwnerID,
            laterOwnerID,
            "A later appProcessOwned() factory call must still bind the same process-wide owner after provider restart.")

        let first = await firstProvider.sampleWithTimeout(context: context)
        XCTAssertTrue(first.unavailableSensors.allSatisfy { $0.reasonCode == "sensor_timeout" })
        let countAfterFirst = await blocker.count()
        let firstActiveAfterFirst = await firstProvider.activeTimedOperationCountForTest()
        let restartedActiveAfterFirst = await restartedProvider.activeTimedOperationCountForTest()
        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(firstActiveAfterFirst, 1)
        XCTAssertEqual(restartedActiveAfterFirst, 1)

        await firstProvider.resetSwapBaselineForLifecycle()
        await restartedProvider.resetSwapBaselineForLifecycle()
        let firstActiveAfterReset = await firstProvider.activeTimedOperationCountForTest()
        let restartedActiveAfterReset = await restartedProvider.activeTimedOperationCountForTest()
        XCTAssertEqual(firstActiveAfterReset, 1)
        XCTAssertEqual(restartedActiveAfterReset, 1)

        let restartedWhileLoserActive = await restartedProvider.sampleWithTimeout(context: context)
        XCTAssertTrue(restartedWhileLoserActive.unavailableSensors.allSatisfy {
            $0.reasonCode == "sensor_timeout_inflight_limit"
        })
        let countAfterRestartedDenied = await blocker.count()
        XCTAssertEqual(
            countAfterRestartedDenied,
            1,
            "A restarted provider must not enter the physical sampler while an earlier timeout loser still owns the shared reservation.")

        let laterWhileLoserActive = await laterProvider.sampleWithTimeout(context: context)
        XCTAssertTrue(laterWhileLoserActive.unavailableSensors.allSatisfy {
            $0.reasonCode == "sensor_timeout_inflight_limit"
        })
        let countAfterLaterDenied = await blocker.count()
        XCTAssertEqual(
            countAfterLaterDenied,
            1,
            "Additional appProcessOwned() providers must observe the same shared capacity and fail closed without starting physical work.")

        await blocker.releaseFirst()
        try await waitUntil {
            await blocker.completedCount() == 1
        }
        try await waitUntil {
            let firstActive = await firstProvider.activeTimedOperationCountForTest()
            let restartedActive = await restartedProvider.activeTimedOperationCountForTest()
            let laterActive = await laterProvider.activeTimedOperationCountForTest()
            return firstActive == 0 && restartedActive == 0 && laterActive == 0
        }

        let postReleaseTask = Task {
            await restartedProvider.sampleWithTimeout(context: context)
        }
        try await waitUntil {
            await blocker.count() == 2
        }
        let firstActiveAfterPostReleaseStart = await firstProvider.activeTimedOperationCountForTest()
        let restartedActiveAfterPostReleaseStart = await restartedProvider.activeTimedOperationCountForTest()
        XCTAssertEqual(firstActiveAfterPostReleaseStart, 1)
        XCTAssertEqual(restartedActiveAfterPostReleaseStart, 1)
        await blocker.releaseAll()
        let postRelease = await postReleaseTask.value
        XCTAssertNotNil(postRelease.memoryFreePercent)
        try await waitUntil {
            let firstActive = await firstProvider.activeTimedOperationCountForTest()
            let restartedActive = await restartedProvider.activeTimedOperationCountForTest()
            let laterActive = await laterProvider.activeTimedOperationCountForTest()
            return firstActive == 0 && restartedActive == 0 && laterActive == 0
        }
    }

    func testAppShellPressureRuntimeUsesOnlyAppProcessOwnedProviderSourceContract() throws {
        let repoRoot = try findRepoRootForSourceContract()
        let appShellURL = repoRoot.appendingPathComponent(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift")
        let appShell = try String(contentsOf: appShellURL, encoding: .utf8)
        XCTAssertTrue(
            appShell.contains("TatwoMacPressureSensorProviderV1.appProcessOwned()"),
            "App launch must use the process-owned pressure provider so runtime restarts cannot bypass the shared physical cap.")

        let sourceRoot = repoRoot.appendingPathComponent(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil))
        var directConstructorSites: [String] = []
        var testOnlyFactoryCallSites: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("TatwoMacPressureSensorProviderV1(") {
                let relativePath = fileURL.path.replacingOccurrences(
                    of: repoRoot.path + "/",
                    with: "")
                directConstructorSites.append("\(relativePath):\(index + 1)")
            }
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(".isolatedForTests(") {
                let relativePath = fileURL.path.replacingOccurrences(
                    of: repoRoot.path + "/",
                    with: "")
                testOnlyFactoryCallSites.append("\(relativePath):\(index + 1)")
            }
        }

        let runtimeSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoMacPressureRuntime.swift"),
            encoding: .utf8)
        let runtimeConstructorSites = directConstructorSites.filter {
            $0.hasPrefix("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoMacPressureRuntime.swift:")
        }
        XCTAssertEqual(
            directConstructorSites,
            runtimeConstructorSites,
            "No production file outside TatwoMacPressureRuntime.swift may construct the macOS pressure provider directly: \(directConstructorSites)")
        XCTAssertEqual(
            runtimeConstructorSites.count,
            2,
            "The only direct constructor sites should be appProcessOwned() plus the DEBUG-only isolatedForTests factory: \(runtimeConstructorSites)")
        XCTAssertTrue(
            runtimeSource.contains("private init("),
            "The macOS pressure provider designated initializer must stay private so production code cannot bypass appProcessOwned().")
        XCTAssertTrue(
            runtimeSource.contains("#if DEBUG\n    nonisolated static func isolatedForTests"),
            "The isolated factory may exist only behind DEBUG for source/runtime tests.")
        XCTAssertTrue(runtimeSource.contains("timedOperationOwner: appProcessTimedOperationOwner"))
        XCTAssertTrue(
            testOnlyFactoryCallSites.isEmpty,
            "Production source must not call the DEBUG-only isolatedForTests factory: \(testOnlyFactoryCallSites)")
    }

    func testMacSensorProviderLifecycleResetDoesNotReopenWhileTimeoutLoserIsPhysicallyActive() async throws {
        let blocker = BlockingMacPressureOverride()
        let provider = TatwoMacPressureSensorProviderV1.isolatedForTests(
            timeoutSeconds: 0.2,
            maximumTimedOperationsInFlight: 1,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let first = await provider.sampleWithTimeout(context: context)
        let countAfterFirst = await blocker.count()
        let activeAfterFirst = await provider.activeTimedOperationCountForTest()
        XCTAssertTrue(first.unavailableSensors.allSatisfy { $0.reasonCode == "sensor_timeout" })
        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(activeAfterFirst, 1)

        let second = await provider.sampleWithTimeout(context: context)
        let countAfterSecond = await blocker.count()
        XCTAssertTrue(second.unavailableSensors.allSatisfy { $0.reasonCode == "sensor_timeout_inflight_limit" })
        XCTAssertEqual(countAfterSecond, 1)

        await provider.resetSwapBaselineForLifecycle()
        let activeAfterLifecycleReset = await provider.activeTimedOperationCountForTest()
        XCTAssertEqual(activeAfterLifecycleReset, 1)

        let thirdWhileLoserStillActive = await provider.sampleWithTimeout(context: context)
        let countAfterThird = await blocker.count()
        XCTAssertTrue(thirdWhileLoserStillActive.unavailableSensors.allSatisfy {
            $0.reasonCode == "sensor_timeout_inflight_limit"
        })
        XCTAssertEqual(countAfterThird, 1)

        await blocker.releaseFirst()
        try await waitUntil {
            await blocker.completedCount() == 1
        }
        try await waitUntil {
            await provider.activeTimedOperationCountForTest() == 0
        }

        let fourthTask = Task {
            await provider.sampleWithTimeout(context: context)
        }
        try await waitUntil {
            await blocker.count() == 2
        }
        let activeAfterOldLoserReleased = await provider.activeTimedOperationCountForTest()
        XCTAssertEqual(activeAfterOldLoserReleased, 1)
        await blocker.releaseAll()
        let fourth = await fourthTask.value
        XCTAssertNotNil(fourth.memoryFreePercent)
        try await waitUntil {
            await provider.activeTimedOperationCountForTest() == 0
        }
    }

    func testMacSensorProviderOldTimeoutLoserCannotReleaseNewEpochReservation() async throws {
        let blocker = BlockingMacPressureOverride()
        let provider = TatwoMacPressureSensorProviderV1.isolatedForTests(
            timeoutSeconds: 0.2,
            maximumTimedOperationsInFlight: 2,
            sampleOverride: { context in
                await blocker.sample(context: context)
            }
        )
        let context = TatwoPressureSamplingContextV1(
            deviceID: "mini-A",
            observedAt: base,
            reason: .appLaunch,
            activeLoopID: nil,
            workers: []
        )

        let first = await provider.sampleWithTimeout(context: context)
        let countAfterFirst = await blocker.count()
        let activeAfterFirst = await provider.activeTimedOperationCountForTest()
        XCTAssertTrue(first.unavailableSensors.allSatisfy { $0.reasonCode == "sensor_timeout" })
        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(activeAfterFirst, 1)

        await provider.resetSwapBaselineForLifecycle()
        let secondTask = Task {
            await provider.sampleWithTimeout(context: context)
        }
        try await waitUntil {
            await blocker.count() == 2
        }
        let activeAfterSecondStarted = await provider.activeTimedOperationCountForTest()
        XCTAssertEqual(activeAfterSecondStarted, 2)

        await blocker.releaseFirst()
        try await waitUntil {
            await blocker.completedCount() == 1
        }
        try await assertActiveTimedOperationCount(
            provider,
            remains: 1,
            durationSeconds: 0.10
        )

        await blocker.releaseAll()
        let second = await secondTask.value
        XCTAssertNotNil(second.memoryFreePercent)
        try await waitUntil {
            await provider.activeTimedOperationCountForTest() == 0
        }
    }

    @MainActor
    func testPressureAdmissionBridgeRequiresInstalledRunningAppRuntime() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let request = makePressureAdmissionRequest(jobID: "job-no-app-runtime", workload: .light)

        let missing = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(request)
        XCTAssertFalse(missing.admissionDecision.accepted)
        XCTAssertFalse(missing.spawned)
        XCTAssertEqual(missing.admissionDecision.reasonCode, "monitor_not_installed")
        XCTAssertNil(missing.reservation)

        let runtime = TatwoAppPressureRuntimeV1(sampler: makeGreenSampler(deviceID: "mini-A"))
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        let stopped = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            makePressureAdmissionRequest(jobID: "job-stopped-app-runtime", workload: .heavy)
        )
        XCTAssertFalse(stopped.admissionDecision.accepted)
        XCTAssertFalse(stopped.spawned)
        XCTAssertEqual(stopped.admissionDecision.reasonCode, "monitor_stopped")
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertFalse(readback.runtimeRunning)
        XCTAssertEqual(readback.registryGeneration, generation)
        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
    }

    @MainActor
    func testPressureAdmissionBridgeUsesInstalledAppRuntimeFreshLeaseBeforeSpawn() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let provider = MacPressureRecordingProvider(readings: greenReadings())
        let sampler = TatwoAppPressureSamplerV1(
            deviceID: "mini-A",
            provider: TatwoDevicePressureSensorProviderV1 { context in
                await provider.sample(context)
            },
            clock: TatwoPressureClockV1(now: clock.now))
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: sampler,
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-app-bridge")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let reservationProbe = MacPressureReservationProbe()
        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-fresh",
            workload: .heavy,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            clock: TatwoPressureClockV1(now: clock.now),
            beforeSpawnWithReservation: { reservation in
                await reservationProbe.record(reservation)
            })

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertTrue(result.enqueued)
        XCTAssertTrue(result.spawned)
        XCTAssertEqual(result.admissionDecision.reasonCode, "pressure_green")
        XCTAssertEqual(result.admissionDecision.runtimeInstanceID, "runtime-mac-app-bridge")
        XCTAssertEqual(result.spawnDecision?.runtimeInstanceID, "runtime-mac-app-bridge")
        let reservationCount = await reservationProbe.count()
        XCTAssertEqual(reservationCount, 1)
        let reasons = await provider.reasons()
        XCTAssertTrue(reasons.contains(.appLaunch))
        XCTAssertTrue(reasons.contains(.preAdmissionImmediate))
        XCTAssertTrue(reasons.contains(.preSpawnRecheck))

        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertTrue(readback.runtimeRunning)
        XCTAssertEqual(readback.registryGeneration, generation)
        XCTAssertEqual(readback.projection.displayClassification, .green)
        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgePersistsSeamJournalAndRejectsDuplicateJob() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-persistent-seam")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-duplicate-fence",
            workload: .heavy,
            at: clock.now())
        let first = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now))
        XCTAssertTrue(first.enqueued)
        XCTAssertTrue(first.spawned)

        let duplicate = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now))
        XCTAssertFalse(duplicate.admissionDecision.accepted)
        XCTAssertFalse(duplicate.enqueued)
        XCTAssertFalse(duplicate.spawned)
        XCTAssertEqual(duplicate.admissionDecision.reasonCode, "admission_already_consumed")

        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 1)
        XCTAssertEqual(counts.spawns, 1)
        XCTAssertEqual(counts.cancels, 0)

        let journal = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertGreaterThanOrEqual(journal.count, 2)
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journal))
        XCTAssertTrue(journal.contains { $0.phase == .spawned })
        let registryEvents = TatwoAppPressureAdmissionBridgeV1.admissionEventsSnapshot()
        XCTAssertEqual(registryEvents.filter { $0.kind == .enqueue }.count, 1)
        XCTAssertEqual(registryEvents.filter { $0.kind == .spawn }.count, 1)

        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeConcurrentDuplicateJobSharesOnePersistentSeam() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-concurrent-persistent-seam")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)

        let buildCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount
        let joinCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedCount
        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-concurrent-duplicate",
            workload: .heavy,
            at: Date())
        let results = await withTaskGroup(
            of: TatwoLocalLoopAdmissionResultV1.self,
            returning: [TatwoLocalLoopAdmissionResultV1].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
                        request,
                        recorder: recorderProbe.recorder())
                }
            }
            var collected: [TatwoLocalLoopAdmissionResultV1] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        let buildCountAfter = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount
        let joinCountAfter = TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedCount

        XCTAssertEqual(results.count, 16)
        XCTAssertEqual(results.filter(\.spawned).count, 1)
        XCTAssertEqual(results.filter(\.enqueued).count, 1)
        XCTAssertEqual(buildCountAfter - buildCountBefore, 1)
        XCTAssertGreaterThanOrEqual(joinCountAfter - joinCountBefore, 1)
        let rejectedReasons = Set(results.filter { !$0.spawned }.map { $0.admissionDecision.reasonCode })
        XCTAssertTrue(rejectedReasons.isSubset(of: [
            "admission_outcome_unproven",
            "admission_already_consumed"
        ]))
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 1)
        XCTAssertEqual(counts.spawns, 1)
        XCTAssertEqual(counts.cancels, 0)
        let journal = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journal))
        XCTAssertEqual(journal.filter { $0.phase == .spawned }.count, 1)
        let registryEvents = TatwoAppPressureAdmissionBridgeV1.admissionEventsSnapshot()
        XCTAssertEqual(registryEvents.filter { $0.kind == .enqueue }.count, 1)
        XCTAssertEqual(registryEvents.filter { $0.kind == .spawn }.count, 1)

        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeConcurrentCallersActuallyJoinPublishedInFlightAdmissionSeamBuild() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let buildProbe = MacPressureAdmissionSeamBuildProbe()
        addTeardownBlock {
            await MainActor.run {
                TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
            }
            await buildProbe.releaseAll()
        }
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-deterministic-join")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        await buildProbe.block(generation: generation)
        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests =
            TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1(
                afterBuildPublished: { observation in
                    await buildProbe.recordPublished(observation)
                },
                beforeBuildCreatesSeam: { observation in
                    await buildProbe.beforeCreatesSeam(observation)
                },
                afterBuildJoined: { observation in
                    await buildProbe.recordJoined(observation)
                })

        let buildCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount
        let joinCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedCount
        let joinedIDsBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedIDsForTests.count
        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-deterministic-join",
            workload: .heavy,
            at: Date())

        let firstTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
                request,
                recorder: recorderProbe.recorder())
        }

        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(generation: generation)
            let createAttemptCount = await buildProbe.createAttemptCount(generation: generation)
            return published != nil && createAttemptCount == 1
        }
        let publishedObservation = await buildProbe.publishedObservation(generation: generation)
        let buildID = try XCTUnwrap(publishedObservation?.buildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, buildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot().count, 0)
        let preJoinJournalCount = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot().count
        XCTAssertEqual(preJoinJournalCount, 0)

        var joinerTasks: [Task<TatwoLocalLoopAdmissionResultV1, Never>] = []
        for _ in 0..<15 {
            joinerTasks.append(Task {
                await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
                    request,
                    recorder: recorderProbe.recorder())
            })
        }
        try await waitUntilOnMainActor {
            await buildProbe.joinCount(buildID: buildID) == 15
        }
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot().count, 0)
        let blockedJoinJournalCount = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot().count
        XCTAssertEqual(blockedJoinJournalCount, 0)
        XCTAssertEqual(
            Set(TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedIDsForTests.suffix(
                TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedIDsForTests.count - joinedIDsBefore)),
            [buildID])
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount - buildCountBefore, 1)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildJoinedCount - joinCountBefore, 15)

        await buildProbe.release(generation: generation)
        var results = [await firstTask.value]
        for task in joinerTasks {
            results.append(await task.value)
        }

        XCTAssertEqual(results.count, 16)
        XCTAssertEqual(results.filter(\.spawned).count, 1)
        XCTAssertEqual(results.filter(\.enqueued).count, 1)
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 1)
        XCTAssertEqual(counts.spawns, 1)
        XCTAssertEqual(counts.cancels, 0)
        let journal = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journal))
        XCTAssertEqual(journal.filter { $0.phase == .spawned }.count, 1)
        let registryEvents = TatwoAppPressureAdmissionBridgeV1.admissionEventsSnapshot()
        XCTAssertEqual(registryEvents.filter { $0.kind == .enqueue }.count, 1)
        XCTAssertEqual(registryEvents.filter { $0.kind == .spawn }.count, 1)

        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testStaleAdmissionSeamBuildCannotCacheOrClearNewGenerationBuild() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let buildProbe = MacPressureAdmissionSeamBuildProbe()
        addTeardownBlock {
            await MainActor.run {
                TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
            }
            await buildProbe.releaseAll()
        }
        let firstRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-stale-build-old")
        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(firstRuntime)
        await firstRuntime.start(reason: .appLaunch, startTimers: false)
        await buildProbe.block(generation: firstGeneration)
        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests =
            TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1(
                afterBuildPublished: { observation in
                    await buildProbe.recordPublished(observation)
                },
                beforeBuildCreatesSeam: { observation in
                    await buildProbe.beforeCreatesSeam(observation)
                },
                afterBuildJoined: { observation in
                    await buildProbe.recordJoined(observation)
                })
        let buildCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount
        let oldRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-build-old",
            workload: .heavy,
            at: Date())
        let oldTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(oldRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(generation: firstGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(generation: firstGeneration)
            return published != nil && createAttemptCount == 1
        }
        let oldPublishedObservation = await buildProbe.publishedObservation(generation: firstGeneration)
        let oldBuildID = try XCTUnwrap(oldPublishedObservation?.buildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, oldBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        let secondRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-stale-build-new")
        let secondGeneration = TatwoAppPressureRuntimeRegistry.install(secondRuntime)
        await secondRuntime.start(reason: .serviceRestart, startTimers: false)
        await buildProbe.block(generation: secondGeneration)
        let newRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-build-new",
            workload: .heavy,
            at: Date())
        let newTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(newRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(generation: secondGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(generation: secondGeneration)
            return published != nil && createAttemptCount == 1
        }
        let newPublishedObservation = await buildProbe.publishedObservation(generation: secondGeneration)
        let newBuildID = try XCTUnwrap(newPublishedObservation?.buildID)
        XCTAssertNotEqual(oldBuildID, newBuildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, newBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        await buildProbe.release(generation: firstGeneration)
        let oldResult = await oldTask.value
        XCTAssertFalse(oldResult.enqueued)
        XCTAssertFalse(oldResult.spawned)
        XCTAssertEqual(oldResult.admissionDecision.reasonCode, "app_runtime_registry_not_current_before_spawn")
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, newBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot().count, 0)
        let preJoinJournalCount = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot().count
        XCTAssertEqual(preJoinJournalCount, 0)

        await buildProbe.release(generation: secondGeneration)
        let newResult = await newTask.value
        XCTAssertTrue(newResult.enqueued)
        XCTAssertTrue(newResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount - buildCountBefore, 2)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        let registryEvents = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(registryEvents.map(\.jobID), [newRequest.jobID, newRequest.jobID])
        XCTAssertEqual(registryEvents.filter { $0.kind == .enqueue }.count, 1)
        XCTAssertEqual(registryEvents.filter { $0.kind == .spawn }.count, 1)
        let journal = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journal))
        XCTAssertEqual(journal.filter { $0.phase == .spawned }.count, 1)

        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
        TatwoAppPressureRuntimeRegistry.clear(generation: secondGeneration)
        await firstRuntime.stop(reason: .appDidSuspend)
        await secondRuntime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testStaleOldAdmissionSeamBuildFinishingAfterNewBuildIsCachedCannotClearOrOverwriteCache() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let buildProbe = MacPressureAdmissionSeamBuildProbe()
        addTeardownBlock {
            await MainActor.run {
                TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
            }
            await buildProbe.releaseAll()
        }
        let firstRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-stale-build-late-old")
        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(firstRuntime)
        await firstRuntime.start(reason: .appLaunch, startTimers: false)
        await buildProbe.block(generation: firstGeneration)
        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests =
            TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1(
                afterBuildPublished: { observation in
                    await buildProbe.recordPublished(observation)
                },
                beforeBuildCreatesSeam: { observation in
                    await buildProbe.beforeCreatesSeam(observation)
                },
                afterBuildJoined: { observation in
                    await buildProbe.recordJoined(observation)
                })
        let buildCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount
        let oldRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-build-late-old",
            workload: .heavy,
            at: Date())
        let oldTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(oldRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(generation: firstGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(generation: firstGeneration)
            return published != nil && createAttemptCount == 1
        }
        let oldPublishedObservation = await buildProbe.publishedObservation(generation: firstGeneration)
        let oldBuildID = try XCTUnwrap(oldPublishedObservation?.buildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, oldBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        let secondRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-stale-build-late-new")
        let secondGeneration = TatwoAppPressureRuntimeRegistry.install(secondRuntime)
        await secondRuntime.start(reason: .serviceRestart, startTimers: false)
        await buildProbe.block(generation: secondGeneration)
        let newRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-build-late-new",
            workload: .heavy,
            at: Date())
        let newTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(newRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(generation: secondGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(generation: secondGeneration)
            return published != nil && createAttemptCount == 1
        }
        let newPublishedObservation = await buildProbe.publishedObservation(generation: secondGeneration)
        let newBuildID = try XCTUnwrap(newPublishedObservation?.buildID)
        XCTAssertNotEqual(oldBuildID, newBuildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, newBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        await buildProbe.release(generation: secondGeneration)
        let newResult = await newTask.value
        XCTAssertTrue(newResult.enqueued)
        XCTAssertTrue(newResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount - buildCountBefore, 2)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        let secondRuntimeGeneration = await secondRuntime.currentGeneration
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        let cachedSeamIDAfterNewCache = try XCTUnwrap(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests)
        let eventsAfterNewCache = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(eventsAfterNewCache.map(\.jobID), [newRequest.jobID, newRequest.jobID])
        let journalAfterNewCache = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journalAfterNewCache))
        XCTAssertEqual(journalAfterNewCache.filter { $0.phase == .spawned }.count, 1)
        let buildCountAfterNewCache = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount

        await buildProbe.release(generation: firstGeneration)
        let oldResult = await oldTask.value
        XCTAssertFalse(oldResult.enqueued)
        XCTAssertFalse(oldResult.spawned)
        XCTAssertEqual(oldResult.admissionDecision.reasonCode, "app_runtime_registry_not_current_before_spawn")
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests,
            cachedSeamIDAfterNewCache)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot(),
            eventsAfterNewCache)
        let journalAfterOldLateCompletion = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertEqual(journalAfterOldLateCompletion, journalAfterNewCache)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount, buildCountAfterNewCache)

        let followUpRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-build-late-new-follow-up",
            workload: .heavy,
            at: Date())
        let followUpResult = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(followUpRequest)
        XCTAssertTrue(followUpResult.enqueued)
        XCTAssertTrue(followUpResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount, buildCountAfterNewCache)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests,
            cachedSeamIDAfterNewCache)
        let finalEvents = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(finalEvents.map(\.jobID), [
            newRequest.jobID,
            newRequest.jobID,
            followUpRequest.jobID,
            followUpRequest.jobID
        ])
        XCTAssertEqual(finalEvents.filter { $0.kind == .enqueue }.count, 2)
        XCTAssertEqual(finalEvents.filter { $0.kind == .spawn }.count, 2)

        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
        TatwoAppPressureRuntimeRegistry.clear(generation: secondGeneration)
        await firstRuntime.stop(reason: .appDidSuspend)
        await secondRuntime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testStaleSameRegistryRuntimeGenerationBuildFinishingAfterNewBuildIsCachedCannotClearOrOverwriteCache() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let buildProbe = MacPressureAdmissionSeamBuildProbe()
        addTeardownBlock {
            await MainActor.run {
                TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
            }
            await buildProbe.releaseAll()
        }
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-stale-same-registry")
        let registryGeneration = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        let firstRuntimeGeneration = await runtime.currentGeneration
        await buildProbe.block(
            registryGeneration: registryGeneration,
            runtimeGeneration: firstRuntimeGeneration)
        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests =
            TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1(
                afterBuildPublished: { observation in
                    await buildProbe.recordPublished(observation)
                },
                beforeBuildCreatesSeam: { observation in
                    await buildProbe.beforeCreatesSeam(observation)
                },
                afterBuildJoined: { observation in
                    await buildProbe.recordJoined(observation)
                })
        let buildCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount
        let oldRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-same-registry-old",
            workload: .heavy,
            at: Date())
        let oldTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(oldRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(
                registryGeneration: registryGeneration,
                runtimeGeneration: firstRuntimeGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(
                registryGeneration: registryGeneration,
                runtimeGeneration: firstRuntimeGeneration)
            return published != nil && createAttemptCount == 1
        }
        let oldPublishedObservation = await buildProbe.publishedObservation(
            registryGeneration: registryGeneration,
            runtimeGeneration: firstRuntimeGeneration)
        let oldBuildID = try XCTUnwrap(oldPublishedObservation?.buildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, oldBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        await runtime.restart(reason: .serviceRestart, startTimers: false)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.isCurrent(runtime, generation: registryGeneration))
        let secondRuntimeGeneration = await runtime.currentGeneration
        XCTAssertNotEqual(firstRuntimeGeneration, secondRuntimeGeneration)
        await buildProbe.block(
            registryGeneration: registryGeneration,
            runtimeGeneration: secondRuntimeGeneration)
        let newRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-same-registry-new",
            workload: .heavy,
            at: Date())
        let newTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(newRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(
                registryGeneration: registryGeneration,
                runtimeGeneration: secondRuntimeGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(
                registryGeneration: registryGeneration,
                runtimeGeneration: secondRuntimeGeneration)
            return published != nil && createAttemptCount == 1
        }
        let newPublishedObservation = await buildProbe.publishedObservation(
            registryGeneration: registryGeneration,
            runtimeGeneration: secondRuntimeGeneration)
        let newBuildID = try XCTUnwrap(newPublishedObservation?.buildID)
        XCTAssertNotEqual(oldBuildID, newBuildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, newBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        await buildProbe.release(
            registryGeneration: registryGeneration,
            runtimeGeneration: secondRuntimeGeneration)
        let newResult = await newTask.value
        XCTAssertTrue(newResult.enqueued)
        XCTAssertTrue(newResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount - buildCountBefore, 2)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        let cachedSeamIDAfterNewCache = try XCTUnwrap(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests)
        let eventsAfterNewCache = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(eventsAfterNewCache.map(\.jobID), [newRequest.jobID, newRequest.jobID])
        let journalAfterNewCache = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journalAfterNewCache))
        XCTAssertEqual(journalAfterNewCache.filter { $0.phase == .spawned }.count, 1)
        let buildCountAfterNewCache = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount

        await buildProbe.release(
            registryGeneration: registryGeneration,
            runtimeGeneration: firstRuntimeGeneration)
        let oldResult = await oldTask.value
        XCTAssertFalse(oldResult.enqueued)
        XCTAssertFalse(oldResult.spawned)
        XCTAssertEqual(
            oldResult.admissionDecision.reasonCode,
            "app_runtime_generation_not_current_before_seam_acquire")
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests,
            cachedSeamIDAfterNewCache)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot(),
            eventsAfterNewCache)
        let journalAfterOldLateCompletion = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertEqual(journalAfterOldLateCompletion, journalAfterNewCache)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount, buildCountAfterNewCache)

        let followUpRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stale-same-registry-follow-up",
            workload: .heavy,
            at: Date())
        let followUpResult = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(followUpRequest)
        XCTAssertTrue(followUpResult.enqueued)
        XCTAssertTrue(followUpResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount, buildCountAfterNewCache)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests,
            cachedSeamIDAfterNewCache)
        let finalEvents = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(finalEvents.map(\.jobID), [
            newRequest.jobID,
            newRequest.jobID,
            followUpRequest.jobID,
            followUpRequest.jobID
        ])
        XCTAssertEqual(finalEvents.filter { $0.kind == .enqueue }.count, 2)
        XCTAssertEqual(finalEvents.filter { $0.kind == .spawn }.count, 2)

        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
        TatwoAppPressureRuntimeRegistry.clear(generation: registryGeneration)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testLateOldSameRegistryRuntimeGenerationBuildCannotClearNewerInFlightBuildPointer() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let buildProbe = MacPressureAdmissionSeamBuildProbe()
        addTeardownBlock {
            await MainActor.run {
                TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests = nil
            }
            await buildProbe.releaseAll()
        }
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A"),
            runtimeInstanceID: "runtime-mac-three-build-same-registry")
        let registryGeneration = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        let firstRuntimeGeneration = await runtime.currentGeneration
        await buildProbe.block(
            registryGeneration: registryGeneration,
            runtimeGeneration: firstRuntimeGeneration)
        TatwoAppPressureRuntimeRegistry.admissionSeamBuildProbeForTests =
            TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1(
                afterBuildPublished: { observation in
                    await buildProbe.recordPublished(observation)
                },
                beforeBuildCreatesSeam: { observation in
                    await buildProbe.beforeCreatesSeam(observation)
                },
                afterBuildJoined: { observation in
                    await buildProbe.recordJoined(observation)
                })
        let buildCountBefore = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount

        let oldRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-three-build-old",
            workload: .heavy,
            at: Date())
        let oldTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(oldRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(
                registryGeneration: registryGeneration,
                runtimeGeneration: firstRuntimeGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(
                registryGeneration: registryGeneration,
                runtimeGeneration: firstRuntimeGeneration)
            return published != nil && createAttemptCount == 1
        }
        let oldPublishedObservation = await buildProbe.publishedObservation(
            registryGeneration: registryGeneration,
            runtimeGeneration: firstRuntimeGeneration)
        let oldBuildID = try XCTUnwrap(oldPublishedObservation?.buildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, oldBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        await runtime.restart(reason: .serviceRestart, startTimers: false)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.isCurrent(runtime, generation: registryGeneration))
        let secondRuntimeGeneration = await runtime.currentGeneration
        XCTAssertNotEqual(firstRuntimeGeneration, secondRuntimeGeneration)
        await buildProbe.block(
            registryGeneration: registryGeneration,
            runtimeGeneration: secondRuntimeGeneration)
        let cachedRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-three-build-cache",
            workload: .heavy,
            at: Date())
        let cachedTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(cachedRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(
                registryGeneration: registryGeneration,
                runtimeGeneration: secondRuntimeGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(
                registryGeneration: registryGeneration,
                runtimeGeneration: secondRuntimeGeneration)
            return published != nil && createAttemptCount == 1
        }
        let cachedPublishedObservation = await buildProbe.publishedObservation(
            registryGeneration: registryGeneration,
            runtimeGeneration: secondRuntimeGeneration)
        let cachedBuildID = try XCTUnwrap(cachedPublishedObservation?.buildID)
        XCTAssertNotEqual(oldBuildID, cachedBuildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, cachedBuildID)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)

        await buildProbe.release(
            registryGeneration: registryGeneration,
            runtimeGeneration: secondRuntimeGeneration)
        let cachedResult = await cachedTask.value
        XCTAssertTrue(cachedResult.enqueued)
        XCTAssertTrue(cachedResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount - buildCountBefore, 2)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        let cachedSeamID = try XCTUnwrap(TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        let eventsAfterCachedBuild = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(eventsAfterCachedBuild.map(\.jobID), [cachedRequest.jobID, cachedRequest.jobID])
        let journalAfterCachedBuild = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journalAfterCachedBuild))
        XCTAssertEqual(journalAfterCachedBuild.filter { $0.phase == .spawned }.count, 1)

        await runtime.restart(reason: .serviceRestart, startTimers: false)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.isCurrent(runtime, generation: registryGeneration))
        let thirdRuntimeGeneration = await runtime.currentGeneration
        XCTAssertNotEqual(secondRuntimeGeneration, thirdRuntimeGeneration)
        await buildProbe.block(
            registryGeneration: registryGeneration,
            runtimeGeneration: thirdRuntimeGeneration)
        let inFlightRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-three-build-inflight",
            workload: .heavy,
            at: Date())
        let inFlightTask = Task {
            await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(inFlightRequest)
        }
        try await waitUntilOnMainActor {
            let published = await buildProbe.publishedObservation(
                registryGeneration: registryGeneration,
                runtimeGeneration: thirdRuntimeGeneration)
            let createAttemptCount = await buildProbe.createAttemptCount(
                registryGeneration: registryGeneration,
                runtimeGeneration: thirdRuntimeGeneration)
            return published != nil && createAttemptCount == 1
        }
        let inFlightPublishedObservation = await buildProbe.publishedObservation(
            registryGeneration: registryGeneration,
            runtimeGeneration: thirdRuntimeGeneration)
        let inFlightBuildID = try XCTUnwrap(inFlightPublishedObservation?.buildID)
        XCTAssertNotEqual(oldBuildID, inFlightBuildID)
        XCTAssertNotEqual(cachedBuildID, inFlightBuildID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, inFlightBuildID)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests, cachedSeamID)

        await buildProbe.release(
            registryGeneration: registryGeneration,
            runtimeGeneration: firstRuntimeGeneration)
        let oldResult = await oldTask.value
        XCTAssertFalse(oldResult.enqueued)
        XCTAssertFalse(oldResult.spawned)
        XCTAssertEqual(
            oldResult.admissionDecision.reasonCode,
            "app_runtime_generation_not_current_before_seam_acquire")
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests, inFlightBuildID)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            secondRuntimeGeneration)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests, cachedSeamID)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot(), eventsAfterCachedBuild)
        let journalAfterOldLateCompletion = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertEqual(journalAfterOldLateCompletion, journalAfterCachedBuild)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount - buildCountBefore, 3)

        await buildProbe.release(
            registryGeneration: registryGeneration,
            runtimeGeneration: thirdRuntimeGeneration)
        let inFlightResult = await inFlightTask.value
        XCTAssertTrue(inFlightResult.enqueued)
        XCTAssertTrue(inFlightResult.spawned)
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.activeAdmissionSeamBuildIDForTests)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasCachedAdmissionSeamForTests)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            thirdRuntimeGeneration)
        let thirdCachedSeamID = try XCTUnwrap(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests)
        XCTAssertNotEqual(thirdCachedSeamID, cachedSeamID)
        let eventsAfterInFlightBuild = TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
        XCTAssertEqual(eventsAfterInFlightBuild.map(\.jobID), [
            cachedRequest.jobID,
            cachedRequest.jobID,
            inFlightRequest.jobID,
            inFlightRequest.jobID
        ])
        let journalAfterInFlightBuild = await TatwoAppPressureAdmissionBridgeV1.admissionJournalSnapshot()
        XCTAssertTrue(TatwoLocalLoopAdmissionJournalEntryV1.verifiesChain(journalAfterInFlightBuild))
        XCTAssertEqual(journalAfterInFlightBuild.filter { $0.phase == .spawned }.count, 1)
        XCTAssertEqual(journalAfterInFlightBuild.map(\.reservation.jobID), [
            inFlightRequest.jobID,
            inFlightRequest.jobID
        ])
        let buildCountAfterInFlightCache = TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount

        let followUpRequest = makePressureAdmissionRequest(
            jobID: "job-app-runtime-three-build-follow-up",
            workload: .heavy,
            at: Date())
        let followUpResult = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(followUpRequest)
        XCTAssertTrue(followUpResult.enqueued)
        XCTAssertTrue(followUpResult.spawned)
        XCTAssertEqual(TatwoAppPressureRuntimeRegistry.admissionSeamBuildStartedCount, buildCountAfterInFlightCache)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamRuntimeGenerationForTests,
            thirdRuntimeGeneration)
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.cachedAdmissionSeamObjectIDForTests,
            thirdCachedSeamID)

        TatwoAppPressureRuntimeRegistry.clear(generation: registryGeneration)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeReadbackReevaluatesLeaseFreshness() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-fresh-readback")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            makePressureAdmissionRequest(
                jobID: "job-app-runtime-readback-freshness",
                workload: .heavy,
                at: clock.now()),
            clock: TatwoPressureClockV1(now: clock.now))
        XCTAssertTrue(result.spawned)

        let freshReadback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertEqual(freshReadback.projection.displayClassification, .green)
        XCTAssertTrue(freshReadback.projection.canRequestHeavyLoop)

        clock.advance(by: 30)
        let staleReadback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertTrue(staleReadback.runtimeRunning)
        XCTAssertEqual(staleReadback.registryGeneration, generation)
        XCTAssertEqual(staleReadback.projection.displayClassification, .unknown)
        XCTAssertFalse(staleReadback.projection.canRequestLightLoop)
        XCTAssertFalse(staleReadback.projection.canRequestHeavyLoop)
        XCTAssertTrue(staleReadback.projection.stopReason?.contains("fresh_pressure_lease_unavailable") == true)

        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsYellowHeavyWithoutSpawn() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let readings = yellowReadings()
        let sampler = TatwoAppPressureSamplerV1(
            deviceID: "mini-A",
            provider: TatwoDevicePressureSensorProviderV1 { _ in
                readings
            },
            clock: TatwoPressureClockV1(now: clock.now))
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: sampler,
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-yellow-heavy")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            makePressureAdmissionRequest(
                jobID: "job-app-runtime-yellow-heavy",
                workload: .heavy,
                at: clock.now()),
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now))
        XCTAssertFalse(result.admissionDecision.accepted)
        XCTAssertEqual(result.admissionDecision.classification, .yellow)
        XCTAssertEqual(result.admissionDecision.reasonCode, "pressure_yellow_heavy_rejected")
        XCTAssertFalse(result.enqueued)
        XCTAssertFalse(result.spawned)
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 0)
        XCTAssertEqual(counts.spawns, 0)
        XCTAssertEqual(counts.cancels, 0)

        TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsWhenRegistryRuntimeIsReplacedBeforeSpawn() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let firstRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-old")
        let secondRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-new")
        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(firstRuntime)
        await firstRuntime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-replaced-before-spawn",
            workload: .heavy,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            beforeSpawnWithReservation: { _ in
                let secondGeneration = await MainActor.run {
                    TatwoAppPressureRuntimeRegistry.install(secondRuntime)
                }
                await secondRuntime.start(reason: .serviceRestart, startTimers: false)
                let firstStillCurrent = await MainActor.run {
                    TatwoAppPressureRuntimeRegistry.isCurrent(
                        firstRuntime,
                        generation: firstGeneration)
                }
                let secondIsCurrent = await MainActor.run {
                    TatwoAppPressureRuntimeRegistry.isCurrent(
                        secondRuntime,
                        generation: secondGeneration)
                }
                XCTAssertFalse(firstStillCurrent)
                XCTAssertTrue(secondIsCurrent)
            })

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertFalse(result.enqueued)
        XCTAssertFalse(result.spawned)
        XCTAssertEqual(
            result.spawnDecision?.reasonCode,
            "app_runtime_registry_not_current_before_spawn")
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 0)
        XCTAssertEqual(counts.spawns, 0)
        XCTAssertEqual(counts.cancels, 1)
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertTrue(readback.runtimeRunning)
        XCTAssertEqual(readback.projection.displayClassification, .green)

        if let generation = readback.registryGeneration {
            TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        } else {
            TatwoAppPressureRuntimeRegistry.clear()
        }
        await firstRuntime.stop(reason: .appDidSuspend)
        await secondRuntime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsWhenRegistryClearedBeforeSpawn() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-cleared")
        let generation = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-cleared-before-spawn",
            workload: .light,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            beforeSpawnWithReservation: { _ in
                await MainActor.run {
                    TatwoAppPressureRuntimeRegistry.clear(generation: generation)
                }
            })

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertFalse(result.enqueued)
        XCTAssertFalse(result.spawned)
        XCTAssertEqual(
            result.spawnDecision?.reasonCode,
            "app_runtime_registry_not_current_before_spawn")
        XCTAssertNil(TatwoAppPressureRuntimeRegistry.runtime)
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 0)
        XCTAssertEqual(counts.spawns, 0)
        XCTAssertEqual(counts.cancels, 1)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsWhenRegistryChangesDuringFinalSpawnFence() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let firstRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-intra-fence-old")
        let secondRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-intra-fence-new")
        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(firstRuntime)
        await firstRuntime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-changed-during-final-fence",
            workload: .heavy,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            spawnAuthorityProbe: TatwoAppPressureSpawnAuthorityFenceProbeV1(
                afterAuthoritySnapshot: {
                    let secondGeneration = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.install(secondRuntime)
                    }
                    await secondRuntime.start(reason: .serviceRestart, startTimers: false)
                    let firstStillCurrent = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.isCurrent(
                            firstRuntime,
                            generation: firstGeneration)
                    }
                    let secondIsCurrent = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.isCurrent(
                            secondRuntime,
                            generation: secondGeneration)
                    }
                    XCTAssertFalse(firstStillCurrent)
                    XCTAssertTrue(secondIsCurrent)
                }))

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertFalse(result.enqueued)
        XCTAssertFalse(result.spawned)
        XCTAssertEqual(
            result.spawnDecision?.reasonCode,
            "app_runtime_registry_not_current_before_spawn")
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 0)
        XCTAssertEqual(counts.spawns, 0)
        XCTAssertEqual(counts.cancels, 1)
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertTrue(readback.runtimeRunning)
        XCTAssertEqual(readback.projection.displayClassification, .green)

        if let generation = readback.registryGeneration {
            TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        } else {
            TatwoAppPressureRuntimeRegistry.clear()
        }
        await firstRuntime.stop(reason: .appDidSuspend)
        await secondRuntime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsWhenRuntimeGenerationChangesDuringFinalSpawnFenceWithoutRegistryReplacement() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-same-object-generation-drift")
        let registryGeneration = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        let initialAuthority = await runtime.authoritySnapshot()
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-generation-drift-during-final-fence",
            workload: .heavy,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            spawnAuthorityProbe: TatwoAppPressureSpawnAuthorityFenceProbeV1(
                afterAuthoritySnapshot: {
                    await runtime.restart(reason: .serviceRestart, startTimers: false)
                    let driftedAuthority = await runtime.authoritySnapshot()
                    let runtimeStillRegistered = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.isCurrent(
                            runtime,
                            generation: registryGeneration)
                    }
                    XCTAssertTrue(runtimeStillRegistered)
                    XCTAssertTrue(driftedAuthority.isRunning)
                    XCTAssertEqual(driftedAuthority.runtimeInstanceID, initialAuthority.runtimeInstanceID)
                    XCTAssertNotEqual(driftedAuthority.currentGeneration, initialAuthority.currentGeneration)
                }))

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertFalse(result.enqueued)
        XCTAssertFalse(result.spawned)
        XCTAssertEqual(
            result.spawnDecision?.reasonCode,
            "app_runtime_generation_not_current_before_spawn")
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 0)
        XCTAssertEqual(counts.spawns, 0)
        XCTAssertEqual(counts.cancels, 1)
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertTrue(readback.runtimeRunning)
        XCTAssertEqual(readback.registryGeneration, registryGeneration)

        TatwoAppPressureRuntimeRegistry.clear(generation: registryGeneration)
        await runtime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsWhenRuntimeStopsDuringFinalSpawnFenceWithoutRegistryReplacement() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-same-object-stop-drift")
        let registryGeneration = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        let initialAuthority = await runtime.authoritySnapshot()
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-stop-drift-during-final-fence",
            workload: .light,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            spawnAuthorityProbe: TatwoAppPressureSpawnAuthorityFenceProbeV1(
                afterAuthoritySnapshot: {
                    await runtime.stop(reason: .appDidSuspend)
                    let stoppedAuthority = await runtime.authoritySnapshot()
                    let runtimeStillRegistered = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.isCurrent(
                            runtime,
                            generation: registryGeneration)
                    }
                    XCTAssertTrue(runtimeStillRegistered)
                    XCTAssertFalse(stoppedAuthority.isRunning)
                    XCTAssertEqual(stoppedAuthority.runtimeInstanceID, initialAuthority.runtimeInstanceID)
                    XCTAssertNotEqual(stoppedAuthority.currentGeneration, initialAuthority.currentGeneration)
                }))

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertFalse(result.enqueued)
        XCTAssertFalse(result.spawned)
        XCTAssertEqual(
            result.spawnDecision?.reasonCode,
            "app_runtime_not_running_before_spawn")
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 0)
        XCTAssertEqual(counts.spawns, 0)
        XCTAssertEqual(counts.cancels, 1)
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertFalse(readback.runtimeRunning)
        XCTAssertEqual(readback.registryGeneration, registryGeneration)

        TatwoAppPressureRuntimeRegistry.clear(generation: registryGeneration)
    }

    @MainActor
    func testPressureAdmissionBridgeSpawnPermitIsLinearizationPointBeforePostPermitRegistryChange() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let permitProbe = MacPressurePermitProbe()
        let firstRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-permit-old")
        let secondRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-permit-new")
        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(firstRuntime)
        await firstRuntime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-permit-linearization",
            workload: .heavy,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            spawnAuthorityProbe: TatwoAppPressureSpawnAuthorityFenceProbeV1(
                afterPermitConsumed: { permit in
                    await permitProbe.record(permit)
                    let permitIsConsumed = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.hasConsumedSpawnAuthorityPermit(permit.permitID)
                    }
                    XCTAssertTrue(permitIsConsumed)
                    let secondGeneration = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.install(secondRuntime)
                    }
                    await secondRuntime.start(reason: .serviceRestart, startTimers: false)
                    let firstStillCurrent = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.isCurrent(
                            firstRuntime,
                            generation: firstGeneration)
                    }
                    let secondIsCurrent = await MainActor.run {
                        TatwoAppPressureRuntimeRegistry.isCurrent(
                            secondRuntime,
                            generation: secondGeneration)
                    }
                    XCTAssertFalse(firstStillCurrent)
                    XCTAssertTrue(secondIsCurrent)
                }))

        XCTAssertTrue(result.admissionDecision.accepted)
        XCTAssertTrue(result.admissionDecision.authorizesSpawn)
        XCTAssertTrue(result.enqueued)
        XCTAssertTrue(result.spawned)
        XCTAssertEqual(result.spawnDecision?.reasonCode, "pressure_green")
        XCTAssertEqual(result.spawnDecision?.runtimeInstanceID, "runtime-mac-permit-old")
        let counts = await recorderProbe.counts()
        XCTAssertEqual(counts.enqueues, 1)
        XCTAssertEqual(counts.spawns, 1)
        XCTAssertEqual(counts.cancels, 0)
        let permits = await permitProbe.permits()
        XCTAssertEqual(permits.count, 1)
        XCTAssertEqual(permits.first?.runtimeInstanceID, "runtime-mac-permit-old")
        XCTAssertEqual(permits.first?.registryGeneration, firstGeneration)
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        XCTAssertTrue(readback.runtimeRunning)
        XCTAssertEqual(readback.projection.displayClassification, .green)

        if let generation = readback.registryGeneration {
            TatwoAppPressureRuntimeRegistry.clear(generation: generation)
        } else {
            TatwoAppPressureRuntimeRegistry.clear()
        }
        await firstRuntime.stop(reason: .appDidSuspend)
        await secondRuntime.stop(reason: .appDidSuspend)
    }

    @MainActor
    func testPressureAdmissionBridgeRejectsDuplicatePermitConsumeAndPrunesOnLifecycleReset() async throws {
        TatwoAppPressureRuntimeRegistry.clear()
        let clock = LockedPressureClock(base)
        let recorderProbe = MacPressureAdmissionRecorderProbe()
        let permitProbe = MacPressurePermitProbe()
        let runtime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-permit-prune")
        let firstGeneration = TatwoAppPressureRuntimeRegistry.install(runtime)
        await runtime.start(reason: .appLaunch, startTimers: false)
        clock.advance(by: 1)

        let request = makePressureAdmissionRequest(
            jobID: "job-app-runtime-permit-prune",
            workload: .heavy,
            at: clock.now())
        let result = await TatwoAppPressureAdmissionBridgeV1.admitAtLastReversiblePoint(
            request,
            recorder: recorderProbe.recorder(),
            clock: TatwoPressureClockV1(now: clock.now),
            spawnAuthorityProbe: TatwoAppPressureSpawnAuthorityFenceProbeV1(
                afterPermitConsumed: { permit in
                    await permitProbe.record(permit)
                }))

        XCTAssertTrue(result.spawned)
        let permits = await permitProbe.permits()
        let permit = try XCTUnwrap(permits.first)
        XCTAssertTrue(TatwoAppPressureRuntimeRegistry.hasConsumedSpawnAuthorityPermit(permit.permitID))
        let duplicateConsume = TatwoAppPressureRuntimeRegistry.consumeSpawnAuthorityPermit(
            permit,
            runtime: runtime)
        XCTAssertEqual(
            duplicateConsume,
            .rejected(
                reasonCode: "app_spawn_authority_permit_already_consumed",
                reason: "Tatwo App pressure spawn authority permit is one-shot and has already been consumed"))

        TatwoAppPressureRuntimeRegistry.clear(generation: firstGeneration)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasConsumedSpawnAuthorityPermit(permit.permitID))
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.consumeSpawnAuthorityPermit(
                permit,
                runtime: runtime),
            .rejected(
                reasonCode: "app_runtime_registry_not_current_before_spawn",
                reason: "Tatwo App pressure runtime registry changed before final spawn authorization; stale registry entry cannot authorize new work"))

        let secondRuntime = TatwoAppPressureRuntimeV1(
            sampler: makeGreenSampler(deviceID: "mini-A", now: clock.now),
            clock: TatwoPressureClockV1(now: clock.now),
            runtimeInstanceID: "runtime-mac-permit-prune-second")
        _ = TatwoAppPressureRuntimeRegistry.install(secondRuntime)
        XCTAssertFalse(TatwoAppPressureRuntimeRegistry.hasConsumedSpawnAuthorityPermit(permit.permitID))
        XCTAssertEqual(
            TatwoAppPressureRuntimeRegistry.consumeSpawnAuthorityPermit(
                permit,
                runtime: secondRuntime),
            .rejected(
                reasonCode: "app_runtime_registry_not_current_before_spawn",
                reason: "Tatwo App pressure runtime registry changed before final spawn authorization; stale registry entry cannot authorize new work"))
        await runtime.stop(reason: .appDidSuspend)
        await secondRuntime.stop(reason: .appDidSuspend)
        TatwoAppPressureRuntimeRegistry.clear()
    }

    func testDevicesPageShowsPressureMonitorAndAdmissionBridgeDoesNotTrustUIProjectionSource() throws {
        let repoRoot = try findRepoRootForSourceContract()
        let devicesPage = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesPage.swift"),
            encoding: .utf8)
        let pressureCard = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicePressureMonitorCard.swift"),
            encoding: .utf8)
        let runtimeSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoMacPressureRuntime.swift"),
            encoding: .utf8)

        XCTAssertTrue(devicesPage.contains("DevicePressureMonitorCard("))
        XCTAssertTrue(pressureCard.contains("TatwoAppPressureAdmissionBridgeV1.currentReadback()"))
        XCTAssertTrue(pressureCard.contains("Loops 派送與壓力"))
        XCTAssertTrue(pressureCard.contains("localityLabel"))
        XCTAssertTrue(pressureCard.contains("hostInventory"))
        XCTAssertTrue(pressureCard.contains("activeLoopCount"))
        XCTAssertTrue(pressureCard.contains("pressureLevel"))
        XCTAssertTrue(pressureCard.contains("pressureLabel"))
        XCTAssertTrue(pressureCard.contains("允許自動借用"))
        XCTAssertFalse(pressureCard.contains("立即借用此設備"))
        XCTAssertFalse(pressureCard.contains("authorizeImmediateBorrow"))
        XCTAssertTrue(pressureCard.contains("DevicesPagePresentation.admissionCaption"))
        XCTAssertTrue(pressureCard.contains("DevicesPagePresentation.borrowTargetDeviceID"))
        XCTAssertFalse(pressureCard.contains("允許 Light"))
        XCTAssertFalse(pressureCard.contains("拒絕 heavy"))
        XCTAssertFalse(pressureCard.contains("permissionPill"))
        XCTAssertTrue(runtimeSource.contains("TatwoAppPressureRuntimeRegistry.entry"))
        XCTAssertTrue(runtimeSource.contains("TatwoLocalLoopAdmissionSeamV1.appRuntimeBacked"))
        XCTAssertTrue(runtimeSource.contains("spawnAuthorityFence"))
        XCTAssertTrue(runtimeSource.contains("TatwoAppPressureSpawnAuthorityPermitV1"))
        XCTAssertTrue(runtimeSource.contains("consumeSpawnAuthorityPermit"))
        XCTAssertTrue(runtimeSource.contains("validateSynchronousSpawnAuthority"))
        XCTAssertTrue(runtimeSource.contains("persistentAdmissionSeam"))
        XCTAssertTrue(runtimeSource.contains("admissionSeamBuild"))
        XCTAssertTrue(runtimeSource.contains("finishPersistentAdmissionSeamBuild"))
        XCTAssertTrue(runtimeSource.contains("admissionSeamBuildStartedCount"))
        XCTAssertTrue(runtimeSource.contains("admissionSeamBuildJoinedCount"))
        XCTAssertTrue(runtimeSource.contains("admissionSeamBuildJoinedIDsForTests"))
        XCTAssertTrue(runtimeSource.contains("admissionSeamBuildProbeForTests"))
        XCTAssertFalse(runtimeSource.contains("ObjectIdentifier(runtime).debugDescription"))
        XCTAssertTrue(runtimeSource.contains("mirrorAdmissionResult"))
        XCTAssertTrue(runtimeSource.contains("admissionJournalSnapshot"))
        XCTAssertTrue(runtimeSource.contains("freshProjection()"))
        XCTAssertTrue(runtimeSource.contains("monitor_not_installed"))
        XCTAssertTrue(runtimeSource.contains("monitor_stopped"))
        XCTAssertTrue(runtimeSource.contains("afterAuthoritySnapshot"))
        XCTAssertTrue(runtimeSource.contains("afterPermitConsumed"))
        XCTAssertTrue(runtimeSource.contains("isCurrent(runtime, generation: permit.registryGeneration)"))
        XCTAssertTrue(runtimeSource.contains("generation: permit.runtimeGeneration"))
        XCTAssertTrue(runtimeSource.contains("validateSynchronousSpawnAuthorityResult"))
        XCTAssertTrue(runtimeSource.contains("app_runtime_generation_not_current_before_spawn"))
        XCTAssertTrue(runtimeSource.contains("app_runtime_generation_not_current_before_seam_acquire"))
        XCTAssertTrue(runtimeSource.contains("app_runtime_not_running_before_spawn"))
        XCTAssertTrue(runtimeSource.contains("app_spawn_authority_permit_already_consumed"))
        XCTAssertTrue(runtimeSource.contains("app_runtime_registry_not_current_before_spawn"))
        XCTAssertFalse(
            runtimeSource.contains("TatwoPressureUIProjectionV1(")
                && runtimeSource.contains("admissionDecision(for:"),
            "The App bridge must not turn a UI projection into an admission lease or service decision.")
    }

    private func makePressureAdmissionRequest(
        jobID: String,
        workload: TatwoPressureWorkerClassV1,
        at: Date? = nil
    ) -> TatwoLoopAdmissionRequestV1 {
        let requestedAt = at ?? base
        return TatwoLoopAdmissionRequestV1(
            jobID: jobID,
            attemptID: "attempt-\(jobID)",
            dispatchNonce: "dispatch-\(jobID)",
            deviceID: "mini-A",
            loopID: "loop-\(jobID)",
            workload: workload,
            contractID: "contract-W1D",
            goalHash: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            planHash: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            requestedAt: requestedAt)
    }

    private func greenReadings() -> TatwoDevicePressureSensorReadingsV1 {
        TatwoDevicePressureSensorReadingsV1(
            memoryFreePercent: 40,
            swapFreeMiB: 2_048,
            dataVolumeFreeGiB: 40,
            load1PerCPU: 0.2,
            thermalWarning: false,
            uiLatencyMilliseconds: 20,
            swapGrowthMiBPerMinute: 0)
    }

    private func yellowReadings() -> TatwoDevicePressureSensorReadingsV1 {
        TatwoDevicePressureSensorReadingsV1(
            memoryFreePercent: 20,
            swapFreeMiB: 800,
            dataVolumeFreeGiB: 20,
            load1PerCPU: 0.8,
            thermalWarning: false,
            uiLatencyMilliseconds: 100,
            swapGrowthMiBPerMinute: 0)
    }

    private func makeGreenSampler(
        deviceID: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> TatwoAppPressureSamplerV1 {
        TatwoAppPressureSamplerV1(
            deviceID: deviceID,
            provider: TatwoDevicePressureSensorProviderV1 { _ in
                TatwoDevicePressureSensorReadingsV1(
                    memoryFreePercent: 40,
                    swapFreeMiB: 2_048,
                    dataVolumeFreeGiB: 40,
                    load1PerCPU: 0.2,
                    thermalWarning: false,
                    uiLatencyMilliseconds: 20,
                    swapGrowthMiBPerMinute: 0)
            },
            clock: TatwoPressureClockV1(now: now)
        )
    }
}

private func findRepoRootForSourceContract() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let appSource = candidate.appendingPathComponent(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift")
        if FileManager.default.fileExists(atPath: appSource.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    XCTFail("could not locate Tatwo Ultrawork repo root for source contract")
    throw CocoaError(.fileNoSuchFile)
}

private func waitUntil(
    timeoutSeconds: TimeInterval = 1.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("condition did not become true before timeout", file: file, line: line)
}

@MainActor
private func waitUntilOnMainActor(
    timeoutSeconds: TimeInterval = 1.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("condition did not become true before timeout", file: file, line: line)
}

private func assertActiveTimedOperationCount(
    _ provider: TatwoMacPressureSensorProviderV1,
    remains expectedCount: Int,
    durationSeconds: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = Date().addingTimeInterval(durationSeconds)
    repeat {
        let activeCount = await provider.activeTimedOperationCountForTest()
        XCTAssertEqual(activeCount, expectedCount, file: file, line: line)
        try await Task.sleep(nanoseconds: 5_000_000)
    } while Date() < deadline
}

private final class LockedPressureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(seconds)
        }
    }
}

private actor MacPressureReservationProbe {
    private var reservations: [TatwoLocalLoopAdmissionReservationV1] = []

    func record(_ reservation: TatwoLocalLoopAdmissionReservationV1) {
        reservations.append(reservation)
    }

    func count() -> Int { reservations.count }
}

private actor MacPressurePermitProbe {
    private var observedPermits: [TatwoAppPressureSpawnAuthorityPermitV1] = []

    func record(_ permit: TatwoAppPressureSpawnAuthorityPermitV1) {
        observedPermits.append(permit)
    }

    func permits() -> [TatwoAppPressureSpawnAuthorityPermitV1] { observedPermits }
}

private actor MacPressureAdmissionRecorderProbe {
    private var enqueued: [TatwoLoopAdmissionRequestV1] = []
    private var spawned: [TatwoLoopAdmissionRequestV1] = []
    private var cancelled: [TatwoLoopAdmissionRequestV1] = []

    nonisolated func recorder() -> TatwoLocalLoopAdmissionRecorderV1 {
        TatwoLocalLoopAdmissionRecorderV1(
            enqueue: { [self] request, _ in
                await recordEnqueue(request)
            },
            spawn: { [self] request, _ in
                await recordSpawn(request)
            },
            cancel: { [self] request, _ in
                await recordCancel(request)
            })
    }

    func counts() -> (enqueues: Int, spawns: Int, cancels: Int) {
        (enqueued.count, spawned.count, cancelled.count)
    }

    private func recordEnqueue(_ request: TatwoLoopAdmissionRequestV1) {
        enqueued.append(request)
    }

    private func recordSpawn(_ request: TatwoLoopAdmissionRequestV1) {
        spawned.append(request)
    }

    private func recordCancel(_ request: TatwoLoopAdmissionRequestV1) {
        cancelled.append(request)
    }
}

private actor MacPressureAdmissionSeamBuildProbe {
    private var blockedGenerations: Set<UInt64> = []
    private var blockedRuntimeGenerationKeys: Set<String> = []
    private var publishedObservations: [UInt64: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1] = [:]
    private var publishedObservationsByRuntimeGeneration: [String: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1] = [:]
    private var createAttemptsByGeneration: [UInt64: Int] = [:]
    private var createAttemptsByRuntimeGeneration: [String: Int] = [:]
    private var joinCountsByBuildID: [String: Int] = [:]
    private var continuationsByGeneration: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var continuationsByRuntimeGeneration: [String: [CheckedContinuation<Void, Never>]] = [:]

    func block(generation: UInt64) {
        blockedGenerations.insert(generation)
    }

    func block(registryGeneration: UInt64, runtimeGeneration: UInt64) {
        blockedRuntimeGenerationKeys.insert(runtimeGenerationKey(
            registryGeneration: registryGeneration,
            runtimeGeneration: runtimeGeneration))
    }

    func recordPublished(_ observation: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) {
        publishedObservations[observation.registryGeneration] = observation
        publishedObservationsByRuntimeGeneration[runtimeGenerationKey(observation)] = observation
    }

    func beforeCreatesSeam(_ observation: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async {
        let key = runtimeGenerationKey(observation)
        createAttemptsByGeneration[observation.registryGeneration, default: 0] += 1
        createAttemptsByRuntimeGeneration[key, default: 0] += 1
        if blockedRuntimeGenerationKeys.contains(key) {
            await withCheckedContinuation { continuation in
                continuationsByRuntimeGeneration[key, default: []].append(continuation)
            }
            return
        }
        guard blockedGenerations.contains(observation.registryGeneration) else { return }
        await withCheckedContinuation { continuation in
            continuationsByGeneration[observation.registryGeneration, default: []].append(continuation)
        }
    }

    func recordJoined(_ observation: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) {
        joinCountsByBuildID[observation.buildID, default: 0] += 1
    }

    func publishedObservation(
        generation: UInt64
    ) -> TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1? {
        publishedObservations[generation]
    }

    func publishedObservation(
        registryGeneration: UInt64,
        runtimeGeneration: UInt64
    ) -> TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1? {
        publishedObservationsByRuntimeGeneration[runtimeGenerationKey(
            registryGeneration: registryGeneration,
            runtimeGeneration: runtimeGeneration)]
    }

    func createAttemptCount(generation: UInt64) -> Int {
        createAttemptsByGeneration[generation, default: 0]
    }

    func createAttemptCount(registryGeneration: UInt64, runtimeGeneration: UInt64) -> Int {
        createAttemptsByRuntimeGeneration[runtimeGenerationKey(
            registryGeneration: registryGeneration,
            runtimeGeneration: runtimeGeneration), default: 0]
    }

    func joinCount(buildID: String) -> Int {
        joinCountsByBuildID[buildID, default: 0]
    }

    func release(generation: UInt64) {
        blockedGenerations.remove(generation)
        let continuations = continuationsByGeneration.removeValue(forKey: generation) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func release(registryGeneration: UInt64, runtimeGeneration: UInt64) {
        let key = runtimeGenerationKey(
            registryGeneration: registryGeneration,
            runtimeGeneration: runtimeGeneration)
        blockedRuntimeGenerationKeys.remove(key)
        let continuations = continuationsByRuntimeGeneration.removeValue(forKey: key) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func releaseAll() {
        blockedGenerations.removeAll(keepingCapacity: true)
        blockedRuntimeGenerationKeys.removeAll(keepingCapacity: true)
        let generationContinuations = continuationsByGeneration.values.flatMap { $0 }
        let runtimeGenerationContinuations = continuationsByRuntimeGeneration.values.flatMap { $0 }
        continuationsByGeneration.removeAll(keepingCapacity: true)
        continuationsByRuntimeGeneration.removeAll(keepingCapacity: true)
        for continuation in generationContinuations + runtimeGenerationContinuations {
            continuation.resume()
        }
    }

    private func runtimeGenerationKey(
        _ observation: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1
    ) -> String {
        runtimeGenerationKey(
            registryGeneration: observation.registryGeneration,
            runtimeGeneration: observation.runtimeGeneration)
    }

    private func runtimeGenerationKey(registryGeneration: UInt64, runtimeGeneration: UInt64) -> String {
        "\(registryGeneration)#\(runtimeGeneration)"
    }
}

private actor MacPressureRecordingProvider {
    private let readings: TatwoDevicePressureSensorReadingsV1
    private var observedReasons: [TatwoPressureSamplingReasonV1] = []

    init(readings: TatwoDevicePressureSensorReadingsV1) {
        self.readings = readings
    }

    func sample(
        _ context: TatwoPressureSamplingContextV1
    ) -> TatwoDevicePressureSensorReadingsV1 {
        observedReasons.append(context.reason)
        return readings
    }

    func reasons() -> [TatwoPressureSamplingReasonV1] { observedReasons }
}

private actor BlockingMacPressureOverride {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var sampleCount = 0
    private var completedSamples = 0

    func sample(
        context: TatwoPressureSamplingContextV1
    ) async -> TatwoDevicePressureSensorReadingsV1 {
        sampleCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        completedSamples += 1
        return TatwoDevicePressureSensorReadingsV1(
            memoryFreePercent: 40,
            swapFreeMiB: 2_048,
            dataVolumeFreeGiB: 40,
            load1PerCPU: 0.2,
            thermalWarning: false,
            uiLatencyMilliseconds: 20,
            swapGrowthMiBPerMinute: 0)
    }

    func count() -> Int { sampleCount }

    func completedCount() -> Int { completedSamples }

    func releaseFirst() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}
