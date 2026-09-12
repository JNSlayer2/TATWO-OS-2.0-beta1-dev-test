import AppKit
import Darwin
import Foundation
import TatwoUltraworkCore

struct TatwoAppPressureRuntimeRegistryAdmissionEventV1: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case enqueue
        case spawn
        case cancel
    }

    let kind: Kind
    let jobID: String
    let requestBindingDigest: String?
    let reasonCode: String
    let recordedAt: Date
}

struct TatwoAppPressureRuntimeRegistryEntryV1 {
    let generation: UInt64
    let runtime: TatwoAppPressureRuntimeV1
    var admissionSeam: TatwoLocalLoopAdmissionSeamV1?
    var admissionSeamRuntimeGeneration: UInt64?
    var admissionSeamBuild: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildV1?
    var admissionEvents: [TatwoAppPressureRuntimeRegistryAdmissionEventV1] = []
}

struct TatwoAppPressureRuntimeRegistryAdmissionSeamBuildV1 {
    let buildID: String
    let registryGeneration: UInt64
    let runtimeGeneration: UInt64
    let task: Task<TatwoLocalLoopAdmissionSeamV1, Never>
}

#if DEBUG
struct TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1: Sendable, Equatable {
    let buildID: String
    let registryGeneration: UInt64
    let runtimeGeneration: UInt64
}

struct TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1: Sendable {
    var afterBuildPublished: (@Sendable (TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async -> Void)?
    var beforeBuildCreatesSeam: (@Sendable (TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async -> Void)?
    var afterBuildJoined: (@Sendable (TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async -> Void)?

    init(
        afterBuildPublished: (@Sendable (TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async -> Void)? = nil,
        beforeBuildCreatesSeam: (@Sendable (TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async -> Void)? = nil,
        afterBuildJoined: (@Sendable (TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1) async -> Void)? = nil
    ) {
        self.afterBuildPublished = afterBuildPublished
        self.beforeBuildCreatesSeam = beforeBuildCreatesSeam
        self.afterBuildJoined = afterBuildJoined
    }
}
#endif

struct TatwoAppPressureSpawnAuthorityPermitV1: Sendable, Equatable {
    let permitID: String
    let registryGeneration: UInt64
    let runtimeInstanceID: String
    let runtimeGeneration: UInt64
    let requestBindingDigest: String
    let dispatchNonce: String
    let reservationID: String
    let admissionAttemptID: String
}

enum TatwoAppPressureSpawnAuthorityPermitConsumeOutcomeV1: Sendable, Equatable {
    case consumed
    case rejected(reasonCode: String, reason: String)

    var isConsumed: Bool {
        if case .consumed = self { return true }
        return false
    }
}

@MainActor
enum TatwoAppPressureRuntimeRegistry {
    private(set) static var entry: TatwoAppPressureRuntimeRegistryEntryV1?
    private(set) static var currentGeneration: UInt64 = 0
    private(set) static var consumedSpawnAuthorityPermitIDs: Set<String> = []
    private(set) static var admissionSeamBuildStartedCount: UInt64 = 0
    private(set) static var admissionSeamBuildJoinedCount: UInt64 = 0
    #if DEBUG
    private(set) static var admissionSeamBuildJoinedIDsForTests: [String] = []
    static var admissionSeamBuildProbeForTests: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildProbeV1?
    static var activeAdmissionSeamBuildIDForTests: String? { entry?.admissionSeamBuild?.buildID }
    static var hasCachedAdmissionSeamForTests: Bool { entry?.admissionSeam != nil }
    static var cachedAdmissionSeamRuntimeGenerationForTests: UInt64? {
        entry?.admissionSeamRuntimeGeneration
    }
    static var cachedAdmissionSeamObjectIDForTests: ObjectIdentifier? {
        guard let seam = entry?.admissionSeam else { return nil }
        return ObjectIdentifier(seam)
    }
    #endif

    static var runtime: TatwoAppPressureRuntimeV1? { entry?.runtime }

    @discardableResult
    static func install(_ runtime: TatwoAppPressureRuntimeV1) -> UInt64 {
        currentGeneration &+= 1
        consumedSpawnAuthorityPermitIDs.removeAll(keepingCapacity: true)
        entry = TatwoAppPressureRuntimeRegistryEntryV1(
            generation: currentGeneration,
            runtime: runtime)
        return currentGeneration
    }

    static func clear(generation expectedGeneration: UInt64? = nil) {
        guard expectedGeneration == nil || expectedGeneration == entry?.generation else { return }
        entry = nil
        consumedSpawnAuthorityPermitIDs.removeAll(keepingCapacity: true)
    }

    static func isCurrent(_ runtime: TatwoAppPressureRuntimeV1, generation: UInt64) -> Bool {
        guard let entry else { return false }
        return entry.generation == generation && entry.runtime === runtime
    }

    static func consumeSpawnAuthorityPermit(
        _ permit: TatwoAppPressureSpawnAuthorityPermitV1,
        runtime: TatwoAppPressureRuntimeV1
    ) -> TatwoAppPressureSpawnAuthorityPermitConsumeOutcomeV1 {
        guard isCurrent(runtime, generation: permit.registryGeneration) else {
            return rejectedConsumeOutcome(
                reasonCode: "app_runtime_registry_not_current_before_spawn",
                reason: "Tatwo App pressure runtime registry changed before final spawn authorization; stale registry entry cannot authorize new work")
        }
        let validation = runtime.validateSynchronousSpawnAuthorityResult(
            runtimeInstanceID: permit.runtimeInstanceID,
            generation: permit.runtimeGeneration
        ) {
            guard isCurrent(runtime, generation: permit.registryGeneration) else {
                return rejectedConsumeOutcome(
                    reasonCode: "app_runtime_registry_not_current_before_spawn",
                    reason: "Tatwo App pressure runtime registry changed inside the spawn permit linearization point")
            }
            guard consumedSpawnAuthorityPermitIDs.insert(permit.permitID).inserted else {
                return rejectedConsumeOutcome(
                    reasonCode: "app_spawn_authority_permit_already_consumed",
                    reason: "Tatwo App pressure spawn authority permit is one-shot and has already been consumed")
            }
            return .consumed
        }
        switch validation {
        case .success(let outcome):
            return outcome
        case .failure(.runtimeNotRunning):
            return rejectedConsumeOutcome(
                reasonCode: "app_runtime_not_running_before_spawn",
                reason: "Tatwo App pressure runtime stopped before final spawn authorization")
        case .failure(.runtimeInstanceMismatch):
            return rejectedConsumeOutcome(
                reasonCode: "app_runtime_instance_not_current_before_spawn",
                reason: "Tatwo App pressure runtime instance changed before final spawn authorization")
        case .failure(.runtimeGenerationMismatch):
            return rejectedConsumeOutcome(
                reasonCode: "app_runtime_generation_not_current_before_spawn",
                reason: "Tatwo App pressure runtime generation changed before final spawn authorization")
        }
    }

    private static func rejectedConsumeOutcome(
        reasonCode: String,
        reason: String
    ) -> TatwoAppPressureSpawnAuthorityPermitConsumeOutcomeV1 {
        .rejected(reasonCode: reasonCode, reason: reason)
    }

    static func hasConsumedSpawnAuthorityPermit(_ permitID: String) -> Bool {
        consumedSpawnAuthorityPermitIDs.contains(permitID)
    }

    static func admissionJournalSnapshot() async -> [TatwoLocalLoopAdmissionJournalEntryV1] {
        guard let seam = entry?.admissionSeam else { return [] }
        return await seam.journalSnapshot()
    }

    static func admissionEventsSnapshot() -> [TatwoAppPressureRuntimeRegistryAdmissionEventV1] {
        entry?.admissionEvents ?? []
    }

    static func persistentAdmissionSeam(
        runtime: TatwoAppPressureRuntimeV1,
        generation: UInt64,
        clock: TatwoPressureClockV1,
        spawnAuthorityFence: @escaping TatwoLocalLoopAdmissionSpawnAuthorityFenceV1
    ) async -> TatwoLocalLoopAdmissionSeamV1? {
        guard isCurrent(runtime, generation: generation) else { return nil }
        let runtimeGeneration = await runtime.currentGeneration
        guard isCurrent(runtime, generation: generation) else { return nil }
        if let seam = entry?.admissionSeam,
           entry?.admissionSeamRuntimeGeneration == runtimeGeneration {
            return seam
        }
        if let build = entry?.admissionSeamBuild,
           build.registryGeneration == generation,
           build.runtimeGeneration == runtimeGeneration {
            admissionSeamBuildJoinedCount &+= 1
            #if DEBUG
            admissionSeamBuildJoinedIDsForTests.append(build.buildID)
            let joinedObservation = TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1(
                buildID: build.buildID,
                registryGeneration: build.registryGeneration,
                runtimeGeneration: build.runtimeGeneration)
            await admissionSeamBuildProbeForTests?.afterBuildJoined?(joinedObservation)
            #endif
            return await finishPersistentAdmissionSeamBuild(
                build,
                runtime: runtime,
                generation: generation)
        }
        let buildID = TatwoLoopJobDigest.sha256(Data([
            "TatwoAppPressureRuntimeRegistryAdmissionSeamBuildV1",
            "registryGeneration=\(generation)",
            "runtimeGeneration=\(runtimeGeneration)",
            "buildSequence=\(admissionSeamBuildStartedCount &+ 1)"
        ].joined(separator: "\u{1f}").utf8))
        let recorder = registryBackedRecorder(forGeneration: generation)
        #if DEBUG
        let buildObservation = TatwoAppPressureRuntimeRegistryAdmissionSeamBuildObservationV1(
            buildID: buildID,
            registryGeneration: generation,
            runtimeGeneration: runtimeGeneration)
        let buildProbe = admissionSeamBuildProbeForTests
        #endif
        let build = TatwoAppPressureRuntimeRegistryAdmissionSeamBuildV1(
            buildID: buildID,
            registryGeneration: generation,
            runtimeGeneration: runtimeGeneration,
            task: Task {
                #if DEBUG
                await buildProbe?.beforeBuildCreatesSeam?(buildObservation)
                #endif
                return await TatwoLocalLoopAdmissionSeamV1.appRuntimeBacked(
                    runtime: runtime,
                    recorder: recorder,
                    clock: clock,
                    spawnAuthorityFence: spawnAuthorityFence)
            })
        admissionSeamBuildStartedCount &+= 1
        entry?.admissionSeamBuild = build
        #if DEBUG
        await admissionSeamBuildProbeForTests?.afterBuildPublished?(buildObservation)
        #endif
        return await finishPersistentAdmissionSeamBuild(
            build,
            runtime: runtime,
            generation: generation)
    }

    static func persistentAdmissionSeamAcquireFailure(
        runtime: TatwoAppPressureRuntimeV1,
        generation: UInt64
    ) async -> (reasonCode: String, reason: String) {
        guard isCurrent(runtime, generation: generation) else {
            return (
                "app_runtime_registry_not_current_before_spawn",
                "Tatwo App pressure runtime registry changed before the persistent admission seam could be acquired")
        }
        return (
            "app_runtime_generation_not_current_before_seam_acquire",
            "Tatwo App pressure runtime generation changed before the persistent admission seam could be acquired")
    }

    private static func finishPersistentAdmissionSeamBuild(
        _ build: TatwoAppPressureRuntimeRegistryAdmissionSeamBuildV1,
        runtime: TatwoAppPressureRuntimeV1,
        generation: UInt64
    ) async -> TatwoLocalLoopAdmissionSeamV1? {
        let seam = await build.task.value
        guard isCurrent(runtime, generation: generation) else {
            if entry?.admissionSeamBuild?.buildID == build.buildID {
                entry?.admissionSeamBuild = nil
            }
            return nil
        }
        let runtimeGeneration = await runtime.currentGeneration
        guard runtimeGeneration == build.runtimeGeneration else {
            if entry?.admissionSeamBuild?.buildID == build.buildID {
                entry?.admissionSeamBuild = nil
            }
            return nil
        }
        guard isCurrent(runtime, generation: generation) else {
            if entry?.admissionSeamBuild?.buildID == build.buildID {
                entry?.admissionSeamBuild = nil
            }
            return nil
        }
        if let existing = entry?.admissionSeam,
           entry?.admissionSeamRuntimeGeneration == build.runtimeGeneration {
            if entry?.admissionSeamBuild?.buildID == build.buildID {
                entry?.admissionSeamBuild = nil
            }
            return existing
        }
        guard entry?.admissionSeamBuild?.buildID == build.buildID else { return nil }
        entry?.admissionSeam = seam
        entry?.admissionSeamRuntimeGeneration = build.runtimeGeneration
        entry?.admissionSeamBuild = nil
        return seam
    }

    private static func registryBackedRecorder(
        forGeneration generation: UInt64
    ) -> TatwoLocalLoopAdmissionRecorderV1 {
        TatwoLocalLoopAdmissionRecorderV1(
            enqueue: { request, decision in
                await MainActor.run {
                    recordAdmissionEvent(
                        generation: generation,
                        kind: .enqueue,
                        request: request,
                        decision: decision)
                }
            },
            spawn: { request, decision in
                await MainActor.run {
                    recordAdmissionEvent(
                        generation: generation,
                        kind: .spawn,
                        request: request,
                        decision: decision)
                }
            },
            cancel: { request, decision in
                await MainActor.run {
                    recordAdmissionEvent(
                        generation: generation,
                        kind: .cancel,
                        request: request,
                        decision: decision)
                }
            })
    }

    private static func recordAdmissionEvent(
        generation: UInt64,
        kind: TatwoAppPressureRuntimeRegistryAdmissionEventV1.Kind,
        request: TatwoLoopAdmissionRequestV1,
        decision: TatwoLoopAdmissionDecisionV1
    ) {
        guard entry?.generation == generation else { return }
        entry?.admissionEvents.append(TatwoAppPressureRuntimeRegistryAdmissionEventV1(
            kind: kind,
            jobID: request.jobID,
            requestBindingDigest: try? request.bindingDigest(),
            reasonCode: decision.reasonCode,
            recordedAt: decision.decidedAt))
        let maxEvents = 512
        if let count = entry?.admissionEvents.count, count > maxEvents {
            entry?.admissionEvents.removeFirst(count - maxEvents)
        }
    }
}

private final class TatwoMacPressureTimeoutRaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func install(_ task: Task<Void, Never>) {
        var shouldCancel = false
        lock.withLock {
            if continuation == nil {
                shouldCancel = true
            } else {
                tasks.append(task)
            }
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func resolve(_ value: T) {
        let continuationToResume: CheckedContinuation<T, Never>?
        let tasksToCancel: [Task<Void, Never>]
        lock.lock()
        continuationToResume = continuation
        continuation = nil
        tasksToCancel = tasks
        tasks = []
        lock.unlock()
        guard let continuationToResume else { return }
        for task in tasksToCancel {
            task.cancel()
        }
        continuationToResume.resume(returning: value)
    }
}

actor TatwoMacPressureTimedOperationOwnerV1 {
    struct Reservation: Sendable {
        let id: UInt64
        let epoch: UInt64
    }

    private let maximumTimedOperationsInFlight: Int
    private var timedOperationsInFlightByID: [UInt64: UInt64] = [:]
    private var nextTimedOperationID: UInt64 = 0
    private var timedOperationLifecycleEpoch: UInt64 = 0

    init(maximumTimedOperationsInFlight: Int = 1) {
        self.maximumTimedOperationsInFlight = max(1, min(maximumTimedOperationsInFlight, 4))
    }

    @discardableResult
    func reserveTimedSensorOperation() -> Reservation? {
        guard timedOperationsInFlightByID.count < maximumTimedOperationsInFlight else {
            return nil
        }
        nextTimedOperationID &+= 1
        let id = nextTimedOperationID
        let epoch = timedOperationLifecycleEpoch
        timedOperationsInFlightByID[id] = epoch
        return Reservation(id: id, epoch: epoch)
    }

    func releaseTimedSensorOperation(reservation: Reservation) {
        guard timedOperationsInFlightByID[reservation.id] == reservation.epoch else { return }
        timedOperationsInFlightByID.removeValue(forKey: reservation.id)
    }

    func resetLifecycle() {
        timedOperationLifecycleEpoch &+= 1
    }

    func activeTimedOperationCountForTest() -> Int {
        timedOperationsInFlightByID.count
    }
}

actor TatwoMacPressureSensorProviderV1 {
    private struct SwapProbe: Sendable {
        let freeMiB: Double
        let usedMiB: Double
    }

    private struct ProbeBundle: Sendable {
        let memory: SensorProbe<Double>
        let swap: SensorProbe<SwapProbe>
        let dataFree: SensorProbe<Double>
        let load: SensorProbe<Double>
        let thermal: SensorProbe<Bool>
        let uiLatency: SensorProbe<Double>
    }

    private enum SensorProbe<T: Sendable>: Sendable {
        case value(T)
        case unavailable(TatwoPressureSensorNameV1, String)
    }

    private static let appProcessTimedOperationOwner = TatwoMacPressureTimedOperationOwnerV1(
        maximumTimedOperationsInFlight: 1)

    private let dataVolumeURL: URL
    private let timeoutSeconds: TimeInterval
    private let sampleOverride: (@Sendable (TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1)?
    private var previousSwap: (usedMiB: Double, observedAt: Date)?
    private var hostInventoryCollector = TatwoDeviceHostInventoryCollector()
    private let maximumSwapBaselineAgeSeconds: TimeInterval
    private let timedOperationOwner: TatwoMacPressureTimedOperationOwnerV1

    private init(
        dataVolumeURL: URL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true),
        timeoutSeconds: TimeInterval = 2.0,
        maximumSwapBaselineAgeSeconds: TimeInterval = 10.0,
        maximumTimedOperationsInFlight: Int = 1,
        sampleOverride: (@Sendable (TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1)? = nil,
        timedOperationOwner: TatwoMacPressureTimedOperationOwnerV1? = nil
    ) {
        self.dataVolumeURL = dataVolumeURL
        self.timeoutSeconds = max(0.1, min(timeoutSeconds, 10.0))
        self.maximumSwapBaselineAgeSeconds = max(0.1, min(maximumSwapBaselineAgeSeconds, 120.0))
        self.sampleOverride = sampleOverride
        self.timedOperationOwner = timedOperationOwner
            ?? TatwoMacPressureTimedOperationOwnerV1(
                maximumTimedOperationsInFlight: maximumTimedOperationsInFlight)
    }

    nonisolated static func appProcessOwned(
        dataVolumeURL: URL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true),
        timeoutSeconds: TimeInterval = 2.0,
        maximumSwapBaselineAgeSeconds: TimeInterval = 10.0,
        sampleOverride: (@Sendable (TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1)? = nil
    ) -> TatwoMacPressureSensorProviderV1 {
        TatwoMacPressureSensorProviderV1(
            dataVolumeURL: dataVolumeURL,
            timeoutSeconds: timeoutSeconds,
            maximumSwapBaselineAgeSeconds: maximumSwapBaselineAgeSeconds,
            maximumTimedOperationsInFlight: 1,
            sampleOverride: sampleOverride,
            timedOperationOwner: appProcessTimedOperationOwner)
    }

    #if DEBUG
    nonisolated static func isolatedForTests(
        dataVolumeURL: URL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true),
        timeoutSeconds: TimeInterval = 2.0,
        maximumSwapBaselineAgeSeconds: TimeInterval = 10.0,
        maximumTimedOperationsInFlight: Int = 1,
        sampleOverride: (@Sendable (TatwoPressureSamplingContextV1) async -> TatwoDevicePressureSensorReadingsV1)? = nil,
        timedOperationOwner: TatwoMacPressureTimedOperationOwnerV1? = nil
    ) -> TatwoMacPressureSensorProviderV1 {
        TatwoMacPressureSensorProviderV1(
            dataVolumeURL: dataVolumeURL,
            timeoutSeconds: timeoutSeconds,
            maximumSwapBaselineAgeSeconds: maximumSwapBaselineAgeSeconds,
            maximumTimedOperationsInFlight: maximumTimedOperationsInFlight,
            sampleOverride: sampleOverride,
            timedOperationOwner: timedOperationOwner)
    }
    #endif

    nonisolated func provider() -> TatwoDevicePressureSensorProviderV1 {
        TatwoDevicePressureSensorProviderV1 { context in
            await self.sampleWithTimeout(context: context)
        }
    }

    func sampleWithTimeout(
        context: TatwoPressureSamplingContextV1
    ) async -> TatwoDevicePressureSensorReadingsV1 {
        guard let timedOperationReservation = await timedOperationOwner.reserveTimedSensorOperation() else {
            return TatwoDevicePressureSensorReadingsV1.unavailable("sensor_timeout_inflight_limit")
        }
        if let sampleOverride {
            let owner = timedOperationOwner
            return await Self.raceTimeout(
                timeoutSeconds: timeoutSeconds,
                timeoutValue: TatwoDevicePressureSensorReadingsV1.unavailable("sensor_timeout"),
                onOperationFinished: {
                    await owner.releaseTimedSensorOperation(reservation: timedOperationReservation)
                }
            ) {
                await sampleOverride(context)
            }
        }
        let owner = timedOperationOwner
        let collectedBundle: ProbeBundle? = await Self.raceTimeout(
            timeoutSeconds: timeoutSeconds,
            timeoutValue: Optional<ProbeBundle>.none,
            onOperationFinished: {
                await owner.releaseTimedSensorOperation(reservation: timedOperationReservation)
            }
        ) { [dataVolumeURL] in
            Optional.some(await Self.collectProbes(dataVolumeURL: dataVolumeURL))
        }
        guard let bundle = collectedBundle else {
            return TatwoDevicePressureSensorReadingsV1.unavailable("sensor_timeout")
        }
        return readings(from: bundle, context: context)
    }

    private nonisolated static func raceTimeout<T: Sendable>(
        timeoutSeconds: TimeInterval,
        timeoutValue: T,
        onOperationFinished: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let box = TatwoMacPressureTimeoutRaceBox(continuation)
            let operationTask = Task {
                let value = await operation()
                await onOperationFinished()
                box.resolve(value)
            }
            let timeoutTask = Task {
                let bounded = max(0.001, min(timeoutSeconds, 10.0))
                let nanoseconds = UInt64((bounded * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanoseconds)
                box.resolve(timeoutValue)
            }
            box.install(operationTask)
            box.install(timeoutTask)
        }
    }

    func resetSwapBaselineForLifecycle() async {
        previousSwap = nil
        await timedOperationOwner.resetLifecycle()
    }

    func activeTimedOperationCountForTest() async -> Int {
        await timedOperationOwner.activeTimedOperationCountForTest()
    }

    func timedOperationOwnerIdentityForTest() -> ObjectIdentifier {
        ObjectIdentifier(timedOperationOwner)
    }

    private nonisolated static func collectProbes(
        dataVolumeURL: URL
    ) async -> ProbeBundle {
        let memory = memoryFreePercent()
        if Task.isCancelled {
            return ProbeBundle(
                memory: memory,
                swap: .unavailable(.swapFreeMiB, "sensor_cancelled"),
                dataFree: .unavailable(.dataVolumeFreeGiB, "sensor_cancelled"),
                load: .unavailable(.load1PerCPU, "sensor_cancelled"),
                thermal: .unavailable(.thermalWarning, "sensor_cancelled"),
                uiLatency: .unavailable(.uiLatencyMilliseconds, "sensor_cancelled"))
        }
        let swap = swapUsage()
        if Task.isCancelled {
            return ProbeBundle(
                memory: memory,
                swap: swap,
                dataFree: .unavailable(.dataVolumeFreeGiB, "sensor_cancelled"),
                load: .unavailable(.load1PerCPU, "sensor_cancelled"),
                thermal: .unavailable(.thermalWarning, "sensor_cancelled"),
                uiLatency: .unavailable(.uiLatencyMilliseconds, "sensor_cancelled"))
        }
        let dataFree = dataVolumeFreeGiB(url: dataVolumeURL)
        if Task.isCancelled {
            return ProbeBundle(
                memory: memory,
                swap: swap,
                dataFree: dataFree,
                load: .unavailable(.load1PerCPU, "sensor_cancelled"),
                thermal: .unavailable(.thermalWarning, "sensor_cancelled"),
                uiLatency: .unavailable(.uiLatencyMilliseconds, "sensor_cancelled"))
        }
        let load = load1PerCPU()
        if Task.isCancelled {
            return ProbeBundle(
                memory: memory,
                swap: swap,
                dataFree: dataFree,
                load: load,
                thermal: .unavailable(.thermalWarning, "sensor_cancelled"),
                uiLatency: .unavailable(.uiLatencyMilliseconds, "sensor_cancelled"))
        }
        let thermal = thermalWarning()
        if Task.isCancelled {
            return ProbeBundle(
                memory: memory,
                swap: swap,
                dataFree: dataFree,
                load: load,
                thermal: thermal,
                uiLatency: .unavailable(.uiLatencyMilliseconds, "sensor_cancelled"))
        }
        let uiLatency = await uiLatencyMilliseconds()
        return ProbeBundle(
            memory: memory,
            swap: swap,
            dataFree: dataFree,
            load: load,
            thermal: thermal,
            uiLatency: uiLatency)
    }

    private func readings(
        from bundle: ProbeBundle,
        context: TatwoPressureSamplingContextV1
    ) -> TatwoDevicePressureSensorReadingsV1 {
        var unavailable: [TatwoPressureSensorUnavailableV1] = []

        let memoryValue = appendUnavailable(bundle.memory, into: &unavailable)
        let swapValue = appendUnavailable(bundle.swap, into: &unavailable)
        let dataValue = appendUnavailable(bundle.dataFree, into: &unavailable)
        let loadValue = appendUnavailable(bundle.load, into: &unavailable)
        let thermalValue = appendUnavailable(bundle.thermal, into: &unavailable)
        let uiLatencyValue = appendUnavailable(bundle.uiLatency, into: &unavailable)
        let swapGrowth = swapGrowthMiBPerMinute(
            current: swapValue,
            observedAt: context.observedAt,
            unavailable: &unavailable)
        let hostInventory = hostInventoryCollector.collect(
            activeLoopCount: TatwoDeviceHostInventoryV1.activeLoopCount(
                workers: context.workers,
                activeLoopID: context.activeLoopID),
            connectionStatus: .local)

        return TatwoDevicePressureSensorReadingsV1(
            memoryFreePercent: memoryValue,
            swapFreeMiB: swapValue?.freeMiB,
            dataVolumeFreeGiB: dataValue,
            load1PerCPU: loadValue,
            thermalWarning: thermalValue,
            uiLatencyMilliseconds: uiLatencyValue,
            swapGrowthMiBPerMinute: swapGrowth,
            unavailableSensors: unavailable,
            hostInventory: hostInventory
        )
    }

    private func appendUnavailable<T>(
        _ probe: SensorProbe<T>,
        into unavailable: inout [TatwoPressureSensorUnavailableV1]
    ) -> T? {
        switch probe {
        case .value(let value):
            return value
        case .unavailable(let sensor, let reason):
            unavailable.append(TatwoPressureSensorUnavailableV1(sensor: sensor, reasonCode: reason))
            return nil
        }
    }

    private func swapGrowthMiBPerMinute(
        current: SwapProbe?,
        observedAt: Date,
        unavailable: inout [TatwoPressureSensorUnavailableV1]
    ) -> Double? {
        guard let current else {
            unavailable.append(TatwoPressureSensorUnavailableV1(
                sensor: .swapGrowthMiBPerMinute,
                reasonCode: "swap_usage_unavailable"))
            return nil
        }
        defer { previousSwap = (current.usedMiB, observedAt) }
        guard let previousSwap else {
            unavailable.append(TatwoPressureSensorUnavailableV1(
                sensor: .swapGrowthMiBPerMinute,
                reasonCode: "swap_growth_baseline_missing"))
            return nil
        }
        let elapsedMinutes = observedAt.timeIntervalSince(previousSwap.observedAt) / 60
        guard elapsedMinutes.isFinite, elapsedMinutes > 0 else {
            unavailable.append(TatwoPressureSensorUnavailableV1(
                sensor: .swapGrowthMiBPerMinute,
                reasonCode: "swap_growth_interval_invalid"))
            return nil
        }
        guard observedAt.timeIntervalSince(previousSwap.observedAt) <= maximumSwapBaselineAgeSeconds else {
            unavailable.append(TatwoPressureSensorUnavailableV1(
                sensor: .swapGrowthMiBPerMinute,
                reasonCode: "swap_growth_baseline_stale"))
            return nil
        }
        return max(0, (current.usedMiB - previousSwap.usedMiB) / elapsedMinutes)
    }

    private nonisolated static func memoryFreePercent() -> SensorProbe<Double> {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return .unavailable(.memoryFreePercent, "host_page_size_failed")
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .unavailable(.memoryFreePercent, "host_statistics64_failed")
        }
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalBytes > 0 else {
            return .unavailable(.memoryFreePercent, "physical_memory_unavailable")
        }
        let availablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        let availableBytes = Double(availablePages) * Double(pageSize)
        return .value((availableBytes / totalBytes) * 100)
    }

    private nonisolated static func swapUsage() -> SensorProbe<SwapProbe> {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else {
            return .unavailable(.swapFreeMiB, "swap_sysctl_failed")
        }
        let totalMiB = Double(usage.xsu_total) / 1_048_576
        let usedMiB = Double(usage.xsu_used) / 1_048_576
        guard totalMiB.isFinite, usedMiB.isFinite, totalMiB >= usedMiB, totalMiB >= 0 else {
            return .unavailable(.swapFreeMiB, "swap_parse_failed")
        }
        return .value(SwapProbe(freeMiB: totalMiB - usedMiB, usedMiB: usedMiB))
    }

    private nonisolated static func dataVolumeFreeGiB(url: URL) -> SensorProbe<Double> {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            let important = values.volumeAvailableCapacityForImportantUsage
            let fallback = values.volumeAvailableCapacity.map(Int64.init)
            guard let bytes = important ?? fallback, bytes >= 0 else {
                return .unavailable(.dataVolumeFreeGiB, "data_volume_capacity_missing")
            }
            return .value(Double(bytes) / 1_073_741_824)
        } catch {
            return .unavailable(.dataVolumeFreeGiB, "data_volume_capacity_failed")
        }
    }

    private nonisolated static func load1PerCPU() -> SensorProbe<Double> {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 1) == 1 else {
            return .unavailable(.load1PerCPU, "getloadavg_failed")
        }
        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return .value(averages[0] / Double(cpuCount))
    }

    private nonisolated static func thermalWarning() -> SensorProbe<Bool> {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            return .value(false)
        case .serious, .critical:
            return .value(true)
        @unknown default:
            return .unavailable(.thermalWarning, "thermal_state_unknown")
        }
    }

    private nonisolated static func uiLatencyMilliseconds() async -> SensorProbe<Double> {
        let start = DispatchTime.now().uptimeNanoseconds
        await MainActor.run {}
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start else {
            return .unavailable(.uiLatencyMilliseconds, "ui_latency_clock_skew")
        }
        return .value(Double(end - start) / 1_000_000)
    }
}

struct TatwoAppPressureRuntimeReadbackV1: Equatable {
    let projection: TatwoPressureUIProjectionV1
    let runtimeRunning: Bool
    let registryGeneration: UInt64?
}

struct TatwoAppPressureSpawnAuthorityFenceProbeV1: Sendable {
    let afterAuthoritySnapshot: (@Sendable () async -> Void)?
    let afterPermitConsumed: (@Sendable (TatwoAppPressureSpawnAuthorityPermitV1) async -> Void)?

    init(
        afterAuthoritySnapshot: (@Sendable () async -> Void)? = nil,
        afterPermitConsumed: (@Sendable (TatwoAppPressureSpawnAuthorityPermitV1) async -> Void)? = nil
    ) {
        self.afterAuthoritySnapshot = afterAuthoritySnapshot
        self.afterPermitConsumed = afterPermitConsumed
    }
}

@MainActor
enum TatwoAppPressureAdmissionBridgeV1 {
    static func currentReadback() async -> TatwoAppPressureRuntimeReadbackV1 {
        guard let entry = TatwoAppPressureRuntimeRegistry.entry else {
            return TatwoAppPressureRuntimeReadbackV1(
                projection: monitorUnknownProjection(reason: "monitor_not_installed"),
                runtimeRunning: false,
                registryGeneration: nil)
        }
        let running = await entry.runtime.isRunning
        guard running else {
            return TatwoAppPressureRuntimeReadbackV1(
                projection: await entry.runtime.currentProjection()
                    ?? monitorUnknownProjection(reason: "monitor_stopped"),
                runtimeRunning: false,
                registryGeneration: entry.generation)
        }
        let projection = await entry.runtime.freshProjection()
        return TatwoAppPressureRuntimeReadbackV1(
            projection: projection ?? monitorUnknownProjection(reason: "monitor_unknown"),
            runtimeRunning: true,
            registryGeneration: entry.generation)
    }

    static func admitAtLastReversiblePoint(
        _ request: TatwoLoopAdmissionRequestV1,
        recorder: TatwoLocalLoopAdmissionRecorderV1? = nil,
        clock: TatwoPressureClockV1 = TatwoPressureClockV1(),
        spawnAuthorityProbe: TatwoAppPressureSpawnAuthorityFenceProbeV1 = .init(),
        beforeSpawnWithReservation:
            @escaping @Sendable (TatwoLocalLoopAdmissionReservationV1) async -> Void = { _ in }
    ) async -> TatwoLocalLoopAdmissionResultV1 {
        let candidateRequestBinding = try? TatwoLoopAdmissionRequestBindingV1.make(for: request)
        guard let entry = TatwoAppPressureRuntimeRegistry.entry else {
            return monitorUnknownResult(
                request: request,
                requestBinding: candidateRequestBinding,
                reasonCode: "monitor_not_installed",
                reason: "Tatwo App pressure runtime registry has no installed App-owned monitor",
                clock: clock)
        }
        guard await entry.runtime.isRunning else {
            return monitorUnknownResult(
                request: request,
                requestBinding: candidateRequestBinding,
                reasonCode: "monitor_stopped",
                reason: "Tatwo App pressure runtime is stopped; no fresh App lease can authorize work",
                clock: clock)
        }
        let runtime = entry.runtime
        let registryGeneration = entry.generation
        guard let seam = await TatwoAppPressureRuntimeRegistry.persistentAdmissionSeam(
            runtime: runtime,
            generation: registryGeneration,
            clock: clock,
            spawnAuthorityFence: registryCurrentSpawnFence(
                runtime: runtime,
                registryGeneration: registryGeneration,
                clock: clock,
                probe: spawnAuthorityProbe))
        else {
            let acquireFailure = await TatwoAppPressureRuntimeRegistry
                .persistentAdmissionSeamAcquireFailure(
                    runtime: runtime,
                    generation: registryGeneration)
            return monitorUnknownResult(
                request: request,
                requestBinding: candidateRequestBinding,
                reasonCode: acquireFailure.reasonCode,
                reason: acquireFailure.reason,
                clock: clock)
        }
        let result = await seam.admitAtLastReversiblePoint(
            request,
            beforeSpawnWithReservation: beforeSpawnWithReservation)
        await mirrorAdmissionResult(result, to: recorder)
        return result
    }

    private static func mirrorAdmissionResult(
        _ result: TatwoLocalLoopAdmissionResultV1,
        to recorder: TatwoLocalLoopAdmissionRecorderV1?
    ) async {
        guard let recorder else { return }
        if result.enqueued {
            await recorder.recordEnqueue(
                request: result.request,
                decision: result.admissionDecision)
        }
        if result.spawned, let spawnDecision = result.spawnDecision {
            await recorder.recordSpawn(
                request: result.request,
                decision: spawnDecision)
        } else if !result.spawned, let spawnDecision = result.spawnDecision {
            await recorder.recordCancel(
                request: result.request,
                decision: spawnDecision)
        }
    }

    static func admissionJournalSnapshot() async -> [TatwoLocalLoopAdmissionJournalEntryV1] {
        await TatwoAppPressureRuntimeRegistry.admissionJournalSnapshot()
    }

    static func admissionEventsSnapshot() -> [TatwoAppPressureRuntimeRegistryAdmissionEventV1] {
        TatwoAppPressureRuntimeRegistry.admissionEventsSnapshot()
    }

    private static func monitorUnknownResult(
        request: TatwoLoopAdmissionRequestV1,
        requestBinding: TatwoLoopAdmissionRequestBindingV1?,
        reasonCode: String,
        reason: String,
        clock: TatwoPressureClockV1
    ) -> TatwoLocalLoopAdmissionResultV1 {
        TatwoLocalLoopAdmissionResultV1(
            request: request,
            requestBinding: requestBinding,
            reservation: nil,
            admissionDecision: TatwoLoopAdmissionDecisionV1(
                deviceID: request.deviceID,
                loopID: request.loopID,
                workload: request.workload,
                decidedAt: clock.now(),
                classification: .unknown,
                accepted: false,
                reasonCode: reasonCode,
                reason: reason,
                stopAction: .none,
                leaseID: nil,
                requestBindingDigest: try? request.bindingDigest(),
                admissionAttemptID: request.attemptID,
                dispatchNonce: request.dispatchNonce),
            spawnDecision: nil,
            enqueued: false,
            spawned: false)
    }

    private static func registryCurrentSpawnFence(
        runtime: TatwoAppPressureRuntimeV1,
        registryGeneration: UInt64,
        clock: TatwoPressureClockV1,
        probe: TatwoAppPressureSpawnAuthorityFenceProbeV1 = .init()
    ) -> TatwoLocalLoopAdmissionSpawnAuthorityFenceV1 {
        { request, requestBinding, reservation, sourceDecision in
            let authority = await runtime.authoritySnapshot()
            await probe.afterAuthoritySnapshot?()
            guard authority.isRunning,
                  authority.runtimeInstanceID == sourceDecision.runtimeInstanceID,
                  authority.currentGeneration == sourceDecision.runtimeGeneration,
                  sourceDecision.requestBindingDigest == requestBinding.requestBindingDigest,
                  sourceDecision.dispatchNonce == request.dispatchNonce,
                  sourceDecision.admissionAttemptID == request.attemptID,
                  sourceDecision.reservationID == reservation.reservationID
            else {
                return registryNotCurrentDecision(
                    request: request,
                    requestBinding: requestBinding,
                    reservation: reservation,
                    sourceDecision: sourceDecision,
                    clock: clock)
            }
            let permit = spawnAuthorityPermit(
                request: request,
                requestBinding: requestBinding,
                reservation: reservation,
                sourceDecision: sourceDecision,
                registryGeneration: registryGeneration)
            let consumeOutcome = await MainActor.run {
                TatwoAppPressureRuntimeRegistry.consumeSpawnAuthorityPermit(
                    permit,
                    runtime: runtime)
            }
            guard consumeOutcome.isConsumed else {
                if case .rejected(let reasonCode, let reason) = consumeOutcome {
                    return registryNotCurrentDecision(
                        request: request,
                        requestBinding: requestBinding,
                        reservation: reservation,
                        sourceDecision: sourceDecision,
                        clock: clock,
                        reasonCode: reasonCode,
                        reason: reason)
                }
                return registryNotCurrentDecision(
                    request: request,
                    requestBinding: requestBinding,
                    reservation: reservation,
                    sourceDecision: sourceDecision,
                    clock: clock)
            }
            await probe.afterPermitConsumed?(permit)
            return nil
        }
    }

    nonisolated private static func spawnAuthorityPermit(
        request: TatwoLoopAdmissionRequestV1,
        requestBinding: TatwoLoopAdmissionRequestBindingV1,
        reservation: TatwoLocalLoopAdmissionReservationV1,
        sourceDecision: TatwoLoopAdmissionDecisionV1,
        registryGeneration: UInt64
    ) -> TatwoAppPressureSpawnAuthorityPermitV1 {
        let runtimeInstanceID = sourceDecision.runtimeInstanceID ?? "missing-runtime-instance-id"
        let runtimeGeneration = sourceDecision.runtimeGeneration ?? 0
        let admissionAttemptID = sourceDecision.admissionAttemptID ?? "missing-admission-attempt-id"
        let payload = [
            "TatwoAppPressureSpawnAuthorityPermitV1",
            "registryGeneration=\(registryGeneration)",
            "runtimeInstanceID=\(runtimeInstanceID)",
            "runtimeGeneration=\(runtimeGeneration)",
            "requestBindingDigest=\(requestBinding.requestBindingDigest)",
            "dispatchNonce=\(request.dispatchNonce)",
            "reservationID=\(reservation.reservationID)",
            "admissionAttemptID=\(admissionAttemptID)",
            "decisionLeaseDigest=\(sourceDecision.leaseDigest ?? "missing-lease-digest")"
        ].joined(separator: "\u{1f}")
        return TatwoAppPressureSpawnAuthorityPermitV1(
            permitID: TatwoLoopJobDigest.sha256(Data(payload.utf8)),
            registryGeneration: registryGeneration,
            runtimeInstanceID: runtimeInstanceID,
            runtimeGeneration: runtimeGeneration,
            requestBindingDigest: requestBinding.requestBindingDigest,
            dispatchNonce: request.dispatchNonce,
            reservationID: reservation.reservationID,
            admissionAttemptID: admissionAttemptID)
    }

    nonisolated private static func registryNotCurrentDecision(
        request: TatwoLoopAdmissionRequestV1,
        requestBinding: TatwoLoopAdmissionRequestBindingV1,
        reservation: TatwoLocalLoopAdmissionReservationV1,
        sourceDecision: TatwoLoopAdmissionDecisionV1,
        clock: TatwoPressureClockV1,
        reasonCode: String = "app_runtime_registry_not_current_before_spawn",
        reason: String = "Tatwo App pressure runtime registry changed before final spawn authorization; stale runtime cannot authorize new work"
    ) -> TatwoLoopAdmissionDecisionV1 {
        TatwoLoopAdmissionDecisionV1(
            deviceID: request.deviceID,
            loopID: request.loopID,
            workload: request.workload,
            decidedAt: clock.now(),
            classification: .unknown,
            accepted: false,
            reasonCode: reasonCode,
            reason: reason,
            stopAction: .checkpointExistingWork,
            leaseID: sourceDecision.leaseID,
            requestBindingDigest: requestBinding.requestBindingDigest,
            runtimeInstanceID: sourceDecision.runtimeInstanceID,
            runtimeGeneration: sourceDecision.runtimeGeneration,
            admissionAttemptID: sourceDecision.admissionAttemptID,
            dispatchNonce: sourceDecision.dispatchNonce,
            reservationID: reservation.reservationID,
            sourceSnapshotSequence: sourceDecision.sourceSnapshotSequence,
            sourceSampleAttemptID: sourceDecision.sourceSampleAttemptID,
            leaseDigest: sourceDecision.leaseDigest)
    }

    private static func monitorUnknownProjection(reason: String) -> TatwoPressureUIProjectionV1 {
        TatwoPressureUIProjectionV1(
            deviceID: "local-device",
            displayClassification: .unknown,
            lastObservedAt: nil,
            activeLoopID: nil,
            workerIDs: [],
            stopReason: reason,
            canRequestLightLoop: false,
            canRequestHeavyLoop: false)
    }
}
