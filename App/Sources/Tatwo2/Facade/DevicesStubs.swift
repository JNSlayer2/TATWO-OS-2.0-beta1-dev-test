// 來源：TatwoDomainContractsV1.swift:20,917；TatwoDeviceHostInventoryCollector.swift:6；TatwoAppPressureService.swift:531；TatwoSyncModulesRegistry.swift:87,146；DeviceSyncOutbox.swift:117,2703,2739；DeviceLocalActionOutbox.swift:11；TatwoActiveOriginLeaseProjector.swift:5；只保留設備畫面欄位，其餘舊 plumbing 為 fixture；host inventory 使用真實 OS 採集
import Foundation
import Darwin


// MARK: - Domain device snapshot values

enum TatwoDomainDeviceKindV1: String, Codable, Hashable, Sendable { case macMini, macBook, iPad, visionPro, remoteHost, other }
enum TatwoDomainConnectionStateV1: String, Codable, Hashable, Sendable { case connected, syncing, offline }
struct TatwoDomainDeviceV1: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let domainID: String
    let displayName: String
    let kind: TatwoDomainDeviceKindV1
    let connectionState: TatwoDomainConnectionStateV1
    let schemaVersion: Int
    let protocolVersion: Int
    let registeredAt: Date
    let lastHeartbeatAt: Date?
}
enum TatwoDomainSnapshotProducerHealthV1: String, Codable, Hashable, Sendable { case healthy, degraded, failed }
struct TatwoDomainDeviceSnapshotV1: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let protocolVersion: Int
    let domainID: String
    let producerHealth: TatwoDomainSnapshotProducerHealthV1
    let producerReceiptSHA256: String
    let observedAt: Date
    let devices: [TatwoDomainDeviceV1]
}
protocol DomainDeviceSnapshotProvider { func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? }
struct TatwoStaticDomainDeviceSnapshotProvider: DomainDeviceSnapshotProvider, Sendable {
    let snapshot: TatwoDomainDeviceSnapshotV1?
    var now: @Sendable () -> Date = Date.init
    func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? { snapshot }
}
enum TatwoDomainSnapshotValidatorV1 { static func isValid(_ snapshot: TatwoDomainDeviceSnapshotV1, now: Date? = nil) -> Bool { true } }

// MARK: - Device identity, pressure, and inventory

struct EnrolledDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String; let role: String; let enrolledAt: Date; let deviceId: String?
    init(name: String, role: String, enrolledAt: Date, deviceId: String? = nil) { self.name = name; self.role = role; self.enrolledAt = enrolledAt; self.deviceId = deviceId }
}
struct TatwoFlexPrimaryState: Equatable {
    let localDeviceName: String; let currentPrimaryName: String?; let epoch: Int?; let changedAt: Date?
    var localRole: DeviceRole? = nil
    var isLocalPrimary: Bool {
        if let localRole { return localRole == .primary && isAssigned }
        return currentPrimaryName == localDeviceName // screenshot-only legacy initializer
    }
    var isAssigned: Bool { currentPrimaryName != nil }
}
enum TatwoFlexPrimaryReader {
    /// Pure read: missing/invalid identity is unassigned, never a screenshot fixture.
    static func read(
        entry: TatwoEntry = TatwoEntry(),
        registryURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TatwoFlexPrimaryState {
        guard let identity = try? DeviceIdentityStore.readLocal(entry: entry) else {
            return TatwoFlexPrimaryState(
                localDeviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                currentPrimaryName: nil, epoch: nil, changedAt: nil)
        }
        let liveRoot = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? Data(contentsOf: registryURL ?? liveRoot.appendingPathComponent("devices.json")))
            .flatMap { try? decoder.decode([DeviceRecord].self, from: $0) } ?? []
        let primaryName = identity.primaryDeviceID.map { id in
            identity.role == .primary ? identity.name
                : records.first { $0.id.lowercased() == id.lowercased() }?.name ?? id
        }
        return TatwoFlexPrimaryState(
            localDeviceName: identity.name, currentPrimaryName: primaryName,
            epoch: identity.epoch, changedAt: identity.updatedAt, localRole: identity.role)
    }
}
enum TatwoHostMemoryPressureLevelV1: String, Codable, Sendable, Equatable { case normal, warn, urgent, critical, unknown }
enum TatwoDeviceConnectionStatusV1: String, Codable, Sendable, Equatable { case local, online, offline, unknown }
struct TatwoPressureWorkerV1: Sendable, Equatable { let loopID: String? }
struct TatwoDeviceHostInventoryV1: Codable, Sendable, Equatable {
    static let schemaName = "TatwoDeviceHostInventoryV1"
    let schema: String; let hardwareModel: String?; let chipName: String?; let ramTotalBytes: UInt64?; let cpuPercent: Double?; let memoryPressureLevel: TatwoHostMemoryPressureLevelV1?; let connectionStatus: TatwoDeviceConnectionStatusV1?; let activeLoopCount: Int?
    init(schema: String = schemaName, hardwareModel: String? = nil, chipName: String? = nil, ramTotalBytes: UInt64? = nil, cpuPercent: Double? = nil, memoryPressureLevel: TatwoHostMemoryPressureLevelV1? = nil, connectionStatus: TatwoDeviceConnectionStatusV1? = nil, activeLoopCount: Int? = nil) { self.schema=schema; self.hardwareModel=hardwareModel; self.chipName=chipName; self.ramTotalBytes=ramTotalBytes; self.cpuPercent=cpuPercent; self.memoryPressureLevel=memoryPressureLevel; self.connectionStatus=connectionStatus; self.activeLoopCount=activeLoopCount }
    var isEmpty: Bool { hardwareModel == nil && chipName == nil && ramTotalBytes == nil && cpuPercent == nil && memoryPressureLevel == nil && connectionStatus == nil && activeLoopCount == nil }
    static func activeLoopCount(workers: [TatwoPressureWorkerV1], activeLoopID: String?) -> Int { activeLoopID == nil ? workers.count : max(1, workers.count) }
}
// HOST-INVENTORY-COLLECTOR-BEGIN
enum TatwoDeviceHostInventoryCollector {
    struct Sources {
        var string: (String) -> String?
        var memorySize: () -> UInt64?
        var pressure: () -> Int32?
        var cpu: () -> Double?

        static var live: Self {
            .init(string: sysctlString,
                  memorySize: { sysctlValue("hw.memsize", initial: UInt64(0)) },
                  pressure: { sysctlValue("kern.memorystatus_vm_pressure_level", initial: Int32(0)) },
                  cpu: { cpuSampler.sample() })
        }
    }

    // Shared only for the interval CPU counter; the lock covers the sample and previous tick.
    // First observation (or a failed sample) is nil, never a since-boot average or a guess.
    private static let cpuSampler = CPUSampler()

    static func collectOnce(activeLoopCount: Int? = nil,
                            connectionStatus: TatwoDeviceConnectionStatusV1 = .local) -> TatwoDeviceHostInventoryV1? {
        collectOnce(activeLoopCount: activeLoopCount, connectionStatus: connectionStatus, sources: .live)
    }

    static func collectOnce(activeLoopCount: Int? = nil,
                            connectionStatus: TatwoDeviceConnectionStatusV1 = .local,
                            sources: Sources) -> TatwoDeviceHostInventoryV1? {
        func text(_ name: String) -> String? {
            guard let value = sources.string(name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let ram = sources.memorySize()
        let cpu = sources.cpu()
        return .init(hardwareModel: text("hw.model"), chipName: text("machdep.cpu.brand_string"),
                     ramTotalBytes: ram.flatMap { $0 > 0 ? $0 : nil },
                     cpuPercent: cpu.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil },
                     memoryPressureLevel: sources.pressure().flatMap(memoryPressureLevel),
                     connectionStatus: connectionStatus, activeLoopCount: activeLoopCount)
    }

    static func memoryPressureLevel(_ raw: Int32) -> TatwoHostMemoryPressureLevelV1? {
        // XNU exports dispatch levels here, NOT its internal normal=0/warning=1 enum.
        switch raw {
        case Int32(DispatchSource.MemoryPressureEvent.normal.rawValue): return .normal
        case Int32(DispatchSource.MemoryPressureEvent.warning.rawValue): return .warn
        case Int32(DispatchSource.MemoryPressureEvent.critical.rawValue): return .critical
        default: return nil
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0, size > 1, size <= bytes.count,
              bytes[size - 1] == 0 else { return nil }
        return String(bytes: bytes.prefix(size - 1), encoding: .utf8)
    }

    private static func sysctlValue<T: FixedWidthInteger>(_ name: String, initial: T) -> T? {
        var value = initial, size = MemoryLayout<T>.size
        let result = withUnsafeMutableBytes(of: &value) {
            sysctlbyname(name, $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }

    final class CPUSampler: @unchecked Sendable {
        struct Ticks {
            let user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
        }
        private let lock = NSLock()
        private var previous: Ticks?

        func sample(read: () -> Ticks? = CPUSampler.readTicks) -> Double? {
            lock.lock()
            defer { lock.unlock() }
            guard let current = read() else { previous = nil; return nil }
            defer { previous = current }
            guard let previous else { return nil }
            let idle = UInt64(current.idle &- previous.idle)
            let busy = UInt64(current.user &- previous.user) + UInt64(current.system &- previous.system)
                + UInt64(current.nice &- previous.nice)
            let total = idle + busy
            guard total > 0 else { return nil }
            return Double(busy) / Double(total) * 100
        }

        static func readTicks() -> Ticks? {
            var info = host_cpu_load_info_data_t()
            let expected = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            var count = expected
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                    host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS, count == expected else { return nil }
            return .init(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                         idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        }
    }
}
// HOST-INVENTORY-COLLECTOR-END

enum TatwoPressureClassificationV1: String, Codable, Sendable, Equatable { case green, yellow, red, unknown }
struct TatwoPressureUIProjectionV1: Codable, Sendable, Equatable {
    let schema: String; let deviceID: String; let displayClassification: TatwoPressureClassificationV1; let lastObservedAt: Date?; let activeLoopID: String?; let workerIDs: [String]; let stopReason: String?; let canRequestLightLoop: Bool; let canRequestHeavyLoop: Bool; let hostInventory: TatwoDeviceHostInventoryV1?
    init(schema: String = "TatwoPressureUIProjectionV1", deviceID: String, displayClassification: TatwoPressureClassificationV1, lastObservedAt: Date?, activeLoopID: String?, workerIDs: [String], stopReason: String?, canRequestLightLoop: Bool, canRequestHeavyLoop: Bool, hostInventory: TatwoDeviceHostInventoryV1? = nil) { self.schema=schema; self.deviceID=deviceID; self.displayClassification=displayClassification; self.lastObservedAt=lastObservedAt; self.activeLoopID=activeLoopID; self.workerIDs=workerIDs; self.stopReason=stopReason; self.canRequestLightLoop=canRequestLightLoop; self.canRequestHeavyLoop=canRequestHeavyLoop; self.hostInventory=hostInventory }
}
struct TatwoPressureReadback { let projection = TatwoPressureUIProjectionV1(deviceID: "fixture-local", displayClassification: .green, lastObservedAt: Date(), activeLoopID: "fixture-loop", workerIDs: [], stopReason: nil, canRequestLightLoop: true, canRequestHeavyLoop: true, hostInventory: nil); let runtimeRunning = true; let registryGeneration: UInt64? = 1 }
enum TatwoAppPressureAdmissionBridgeV1 { static func currentReadback() async -> TatwoPressureReadback { .init() } }
struct TatwoRemoteDeviceExecutionPolicyV1: Equatable, Sendable { let autoBorrowEnabled: Bool }
struct TatwoRemoteBorrowAuthorizationStore: Sendable {
    static func `default`() -> Self { .init() }
    func devicePolicy(targetDeviceID: String) throws -> TatwoRemoteDeviceExecutionPolicyV1 { .init(autoBorrowEnabled: true) }
    func setAutoBorrow(targetDeviceID: String, enabled: Bool) throws -> TatwoRemoteDeviceExecutionPolicyV1 { .init(autoBorrowEnabled: enabled) }
}
struct TatwoDevicePeerInventoryRecordV1: Codable, Equatable, Sendable { let deviceID: String; let displayName: String; let timestamp: Date; let hostInventory: TatwoDeviceHostInventoryV1 }
enum TatwoDevicePeerInventoryStalenessV1 { static func updatedLabel(timestamp: Date, now: Date) -> String { "剛剛更新" }; static func isStale(timestamp: Date, now: Date) -> Bool { false } }
struct TatwoDevicePeerInventoryStore {
    static let storeDirectoryName = "fixture-device-inventory"
    init(storeURL: URL) {}
    func ingest(channelInventoryDirectory: URL, registeredDevicesDirectory: URL) throws -> Int { 0 }
    func load() throws -> [TatwoDevicePeerInventoryRecordV1] { [] }
    static func channelInventoryDirectory(channelRoot: URL) -> URL { channelRoot }
    static func isSafeDeviceID(_ value: String) -> Bool { !value.isEmpty }
    static func match(records: [TatwoDevicePeerInventoryRecordV1], deviceID: String?, displayName: String) -> TatwoDevicePeerInventoryRecordV1? { records.first { $0.deviceID == deviceID || $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame } }
}

// MARK: - Sync module fixture registry

enum TatwoSyncModuleSectionV1: String, Codable, Sendable, Equatable { case version, data, compute }
enum TatwoSyncModuleTransportV1: String, Codable, Sendable, Equatable { case githubRelease = "github-release", deviceSyncChannel = "device-sync-channel", loopChannel = "loop-channel", manual }
enum TatwoSyncModuleRunStateV1: String, Codable, Sendable, Equatable { case idle, syncing, failed }
struct TatwoSyncModuleDefinitionV1: Codable, Hashable, Sendable, Identifiable {
    let id: String; let section: TatwoSyncModuleSectionV1; let titleZh: String; let plainZh: String; let transport: TatwoSyncModuleTransportV1; let enabled: Bool; let statusProbe: String?; let owningPaths: [String]; let excluded: Bool; let notes: String
    init(id: String, section: TatwoSyncModuleSectionV1, titleZh: String, plainZh: String, transport: TatwoSyncModuleTransportV1 = .manual, enabled: Bool = true, statusProbe: String? = nil, owningPaths: [String] = [], excluded: Bool = false, notes: String = "") { self.id=id; self.section=section; self.titleZh=titleZh; self.plainZh=plainZh; self.transport=transport; self.enabled=enabled; self.statusProbe=statusProbe; self.owningPaths=owningPaths; self.excluded=excluded; self.notes=notes }
}
struct TatwoSyncModuleRuntimeRecordV1: Codable, Sendable, Equatable { var moduleID: String; var state: TatwoSyncModuleRunStateV1 = .idle; var lastSyncAt: Date? = nil; var reason: String? = nil; var updatedAt = Date(timeIntervalSince1970: 0) }
struct TatwoSyncModuleResolvedV1: Identifiable, Sendable, Equatable { var id: String { definition.id }; let definition: TatwoSyncModuleDefinitionV1; let enabled: Bool; let runtime: TatwoSyncModuleRuntimeRecordV1; var runState: TatwoSyncModuleRunStateV1 { runtime.state }; var reason: String? { runtime.reason } }
struct TatwoSyncModulesRegistry: Codable, Hashable, Sendable {
    let modules: [TatwoSyncModuleDefinitionV1]
    // No shipping dispatcher is wired here. Do not advertise five fictional modules.
    static func loadBundled() throws -> Self { .init(modules: []) }
    func module(id: String) -> TatwoSyncModuleDefinitionV1? { modules.first { $0.id == id } }
    func resolvedModules(enablement: TatwoSyncModuleEnablementStore, runtime: TatwoSyncModuleRuntimeStateStore) throws -> [TatwoSyncModuleResolvedV1] { modules.map { .init(definition: $0, enabled: (try? enablement.isEnabled(moduleID: $0.id, registry: self)) ?? $0.enabled, runtime: .init(moduleID: $0.id)) } }
}
struct TatwoSyncModuleEnablementStore: Sendable {
    static func defaultStore(environment: [String:String] = [:], applicationSupportBase: URL? = nil) -> Self { .init() }
    func isEnabled(moduleID: String, registry: TatwoSyncModulesRegistry) throws -> Bool { registry.module(id: moduleID)?.enabled ?? false }
    func setEnabled(_ enabled: Bool, moduleID: String, registry: TatwoSyncModulesRegistry, now: Date = Date()) throws {}
}
struct TatwoSyncModuleRuntimeStateStore: Sendable {
    static func defaultStore(environment: [String:String] = [:], applicationSupportBase: URL? = nil) -> Self { .init() }
    func markSyncing(moduleID: String, registry: TatwoSyncModulesRegistry, now: Date = Date()) throws {}
    func markIdle(moduleID: String, lastSyncAt: Date? = nil, registry: TatwoSyncModulesRegistry, now: Date = Date()) throws {}
    func markFailed(moduleID: String, reason: String, lastSyncAt: Date? = nil, registry: TatwoSyncModulesRegistry, now: Date = Date()) throws {}
}

// MARK: - Disabled old device plumbing (same names, memory-only)

protocol TatwoDomainAuthorityCoordinatorPort {}
struct TatwoDomainAuthorityHTTPTransport: TatwoDomainAuthorityCoordinatorPort { init(baseURL: URL, allowInsecureLoopbackForTesting: Bool, secretProvider: @escaping () -> String?) throws {} }
struct TatwoDomainCoordinatorHTTPTransport { init(baseURL: URL, allowInsecureLoopbackForTesting: Bool, secretProvider: @escaping () -> String?) throws {} }
struct TatwoFileBackedDeviceSyncPersistenceAdapter { init(rootURL: URL, createRootIfMissing: Bool, now: @escaping @Sendable () -> Date) throws {} }
struct TatwoPersistedDomainDeviceSnapshotProvider: DomainDeviceSnapshotProvider { init(persistenceAdapter: TatwoFileBackedDeviceSyncPersistenceAdapter, now: @escaping @Sendable () -> Date) {}; func verifiedSnapshot() -> TatwoDomainDeviceSnapshotV1? { nil } }
final class TatwoSnapshotProducerReceiptHashRelay { var value = String(repeating: "a", count: 64) }
struct TatwoDeviceSyncCore { init(domainID: String, snapshotProducerReceiptSHA256: @escaping () -> String, persistenceAdapter: TatwoFileBackedDeviceSyncPersistenceAdapter, transport: TatwoDomainCoordinatorHTTPTransport, now: @escaping @Sendable () -> Date) {} }

// MARK: - Device sync receipt values

enum DeviceSyncAction { static func canonicalRequestValue(_ value: String) -> String? { ["system-pull","version-pull","db-pull"].contains(value) ? value : nil }; static func canonicalArtifactValue(_ value: String) -> String? { value == "both" ? nil : value } }
struct DeviceSyncOperationKey: Hashable, Identifiable, Sendable { let target: String; let action: String; init(target: String, action: String) { self.target=target; self.action=action.lowercased() }; var id: String { "\(target)::\(action)" }; var displayName: String { action == "system-pull" ? "OS 資料" : action == "version-pull" ? "來源版本" : action } }
struct DeviceSyncIntent: Codable, Equatable, Sendable { let target: String; let action: String; let requestedAt: Date; var operationKey: DeviceSyncOperationKey { .init(target: target, action: action) } }
enum DeviceSyncReceiptPhase: String, Codable, Equatable, CaseIterable, Sendable { case queued, delivered, accepted, transferring, merging, validating, activating, verified, converged, failed, diverged; var progressFraction: Double { switch self { case .queued: 0.08; case .delivered: 0.25; case .accepted: 0.34; case .transferring: 0.48; case .merging: 0.60; case .validating: 0.72; case .activating: 0.84; case .verified: 0.94; case .converged: 1; case .failed: 0.76; case .diverged: 0.88 } } }
struct DeviceSyncProgressPayload: Codable, Equatable, Sendable { let completedUnits: Int?; let totalUnits: Int?; let percent: Int?; let completedBytes: Int64?; let totalBytes: Int64?; let completedItems: Int?; let totalItems: Int?; let completedRepositories: Int?; let totalRepositories: Int?; let elapsedMilliseconds: Int64?; let throughputBytesPerSecond: Double?; let currentItem: String?; init(completedUnits:Int?=nil,totalUnits:Int?=nil,percent:Int?=nil,completedBytes:Int64?=nil,totalBytes:Int64?=nil,completedItems:Int?=nil,totalItems:Int?=nil,completedRepositories:Int?=nil,totalRepositories:Int?=nil,elapsedMilliseconds:Int64?=nil,throughputBytesPerSecond:Double?=nil,currentItem:String?=nil){self.completedUnits=completedUnits;self.totalUnits=totalUnits;self.percent=percent;self.completedBytes=completedBytes;self.totalBytes=totalBytes;self.completedItems=completedItems;self.totalItems=totalItems;self.completedRepositories=completedRepositories;self.totalRepositories=totalRepositories;self.elapsedMilliseconds=elapsedMilliseconds;self.throughputBytesPerSecond=throughputBytesPerSecond;self.currentItem=currentItem}; var hasMeasuredProgress: Bool { completedBytes != nil || completedItems != nil || completedRepositories != nil } }
struct DeviceSyncProgressValue: Equatable, Sendable { enum Provenance: String, Equatable, Sendable { case artifact, phaseDerived, synthetic }; let fraction: Double; let provenance: Provenance; var percentLabel: String { "\(Int((fraction*100).rounded()))%" }; static func make(payload: DeviceSyncProgressPayload?, fallbackPhase: DeviceSyncReceiptPhase, provenance: Provenance = .phaseDerived) -> Self { if let c=payload?.completedBytes, let t=payload?.totalBytes, t>0 { return .init(fraction:min(1,Double(c)/Double(t)), provenance:.artifact) }; return .init(fraction:fallbackPhase.progressFraction, provenance:provenance) } }
struct DeviceSyncSkilletRepositoryReceipt: Codable, Equatable, Sendable { let repositoryID:String; let revisionID:String; let contentDigest:String; let bundleDigest:String; let authorityEpoch:Int; let ledgerSequence:Int; let requestID:String; func isVerified(in receipt: DeviceSyncReceipt)->Bool { true } }
struct DeviceSyncTargetPreservedRepositoryReceipt: Codable, Equatable, Sendable { let repositoryID:String; let revisionID:String; let contentDigest:String; let state:String; let phase:String; let isVerified:Bool }
struct DeviceSyncItemReceipt: Codable, Equatable, Identifiable, Sendable { let id:String; let displayName:String; let phase:DeviceSyncReceiptPhase; let sourceDigest:String?; let appliedDigest:String?; let message:String; let repositories:[DeviceSyncSkilletRepositoryReceipt]?; let targetPreservedRepositories:[DeviceSyncTargetPreservedRepositoryReceipt]?; let progress:DeviceSyncProgressPayload?; var progressValue:DeviceSyncProgressValue { .make(payload:progress,fallbackPhase:phase) } }
struct DeviceSyncConsumerReadback: Codable, Equatable, Identifiable, Sendable { let id:String; let consumerID:String; let consumerKind:String; let sourceItemID:String; let loadedRevision:String; let expectedDigest:String; let loadedDigest:String; let runtimeRef:String; let loadedPath:String; let isLoaded:Bool }
enum DeviceSyncAttestationLevel: String, Codable, Equatable, Sendable { case none, channelClaimed, targetLocallyAttested, unreadable }
struct DeviceSyncAttestationEvidence: Codable, Equatable, Sendable { var level:DeviceSyncAttestationLevel = .none; var provenance:String = "fixture"; var attestedAt:Date?=nil; var consumerReadbacks:[DeviceSyncConsumerReadback]=[]; var consumerReadbackDigest:String?=nil; var detail:String="fixture attestation"; var hasCompleteConsumerReadback:Bool { true } }
struct DeviceSyncReceipt: Codable, Equatable, Sendable {
    let target:String; let action:String; let requestedAt:Date; let result:String; let completedAt:Date; let message:String; let phase:DeviceSyncReceiptPhase?; let requestID:String?; let authorityEpoch:Int?; let ledgerSequence:Int?; let authorityPrimary:String?; let sourceDeviceID:String?; let targetDeviceID:String?; let catalogRevision:String?; let sourceMode:String?; let inventoryDigest:String?; let fallbackAuthorizationID:String?; let fallbackAuthorizationPath:String?; let fallbackAuthorizationDigest:String?; let sourceDigest:String?; let appliedDigest:String?; let sourceRefreshAttemptID:String?; let progress:DeviceSyncProgressPayload?; let items:[DeviceSyncItemReceipt]?; var attestationEvidence=DeviceSyncAttestationEvidence()
    init(target:String,action:String,requestedAt:Date,result:String,completedAt:Date,message:String,phase:DeviceSyncReceiptPhase?=nil,requestID:String?=nil,authorityEpoch:Int?=nil,ledgerSequence:Int?=nil,authorityPrimary:String?=nil,sourceDeviceID:String?=nil,targetDeviceID:String?=nil,catalogRevision:String?=nil,sourceMode:String?=nil,inventoryDigest:String?=nil,fallbackAuthorizationID:String?=nil,fallbackAuthorizationPath:String?=nil,fallbackAuthorizationDigest:String?=nil,sourceDigest:String?=nil,appliedDigest:String?=nil,sourceRefreshAttemptID:String?=nil,progress:DeviceSyncProgressPayload?=nil,items:[DeviceSyncItemReceipt]?=nil){self.target=target;self.action=action;self.requestedAt=requestedAt;self.result=result;self.completedAt=completedAt;self.message=message;self.phase=phase;self.requestID=requestID;self.authorityEpoch=authorityEpoch;self.ledgerSequence=ledgerSequence;self.authorityPrimary=authorityPrimary;self.sourceDeviceID=sourceDeviceID;self.targetDeviceID=targetDeviceID;self.catalogRevision=catalogRevision;self.sourceMode=sourceMode;self.inventoryDigest=inventoryDigest;self.fallbackAuthorizationID=fallbackAuthorizationID;self.fallbackAuthorizationPath=fallbackAuthorizationPath;self.fallbackAuthorizationDigest=fallbackAuthorizationDigest;self.sourceDigest=sourceDigest;self.appliedDigest=appliedDigest;self.sourceRefreshAttemptID=sourceRefreshAttemptID;self.progress=progress;self.items=items}
    var operationKey:DeviceSyncOperationKey{.init(target:target,action:action)}; var effectivePhase:DeviceSyncReceiptPhase{phase ?? (result=="failure" ? .failed : result=="converged" ? .converged : .queued)}; var effectiveRequiredItemIDs:[String]{[]}; var isCatalogCompatible:Bool{true}; var isChannelClaimed:Bool{false}; var isConverged:Bool{effectivePhase == .converged}; var progressFraction:Double{DeviceSyncProgressValue.make(payload:progress,fallbackPhase:effectivePhase).fraction}; var statusLabel:String{effectivePhase.rawValue}; func isItemVerified(_ item:DeviceSyncItemReceipt)->Bool{item.phase == .verified}; static func isSafeIdentifier(_ value:String)->Bool{!value.isEmpty}
}
enum DeviceSyncDigestValidator { static func isSHA256(_ value:String?)->Bool { value?.count == 64 }; static func matches(algorithm:String?,source:String?,applied:String?)->Bool { source != nil && source == applied } }
enum DeviceSyncSourceProvenanceValidator { static let canonical="canonical"; static let runtimeFallback="runtime-fallback"; static func isValid(sourceMode:String?,inventoryDigest:String?,fallbackAuthorizationID:String?,fallbackAuthorizationPath:String?,fallbackAuthorizationDigest:String?,authorityPrimary:String,authorityEpoch:Int)->Bool { true } }
enum DeviceSyncCatalogProjection { static let currentRevision:String?="fixture"; static let systemPullItemNames:[String:String]=["os.issue":"issue.md"]; static func displayName(for id:String)->String{id} }
enum DeviceSyncArtifactIssueScope: Equatable, Sendable { case global; case verifiedBinding(target:String?,action:String?,requestID:String?) }
struct DeviceSyncArtifactIssue: Equatable, Identifiable, Sendable { let id=UUID(); let kind:String; let fileName:String; let message:String; let scope:DeviceSyncArtifactIssueScope; init(kind:String="fixture",fileName:String="fixture",message:String="",scope:DeviceSyncArtifactIssueScope = .global){self.kind=kind;self.fileName=fileName;self.message=message;self.scope=scope} }
struct DeviceSyncSourceRefreshAttempt: Codable, Equatable, Sendable { static let evidenceKind="source-refresh"; let target:String; let action:String; let requestedAt:Date; let completedAt:Date; var operationKey:DeviceSyncOperationKey{.init(target:target,action:action)} }
enum DeviceSyncTransactionState: String, Equatable, Sendable { case preparing, oldMirrorMoveStarted, committedAwaitingACK, recovering, rollbackPending, diverged, unreadable, rolledBack, targetLocallyAttested }
struct DeviceSyncTransactionJournal: Equatable, Sendable { let requestID:String; let authorityEpoch:Int; let ledgerSequence:Int; let updatedAt:Date }
struct DeviceSyncTransactionProjection: Equatable, Identifiable, Sendable { var id:String{"\(target)::\(action)::\(journal.requestID)"}; let target:String; let action:String; let state:DeviceSyncTransactionState; let journal:DeviceSyncTransactionJournal }
enum DeviceSyncOperationIndex {
    static func targetNames(pending:[DeviceSyncOperationKey:DeviceSyncIntent],receipts:[DeviceSyncOperationKey:DeviceSyncReceipt],sourceRefreshAttempts:[DeviceSyncOperationKey:DeviceSyncSourceRefreshAttempt])->[String]{Array(Set(pending.keys.map(\.target)+receipts.keys.map(\.target)+sourceRefreshAttempts.keys.map(\.target)))}
    static func operationKeys(for target:String,pending:[DeviceSyncOperationKey:DeviceSyncIntent],receipts:[DeviceSyncOperationKey:DeviceSyncReceipt],sourceRefreshAttempts:[DeviceSyncOperationKey:DeviceSyncSourceRefreshAttempt])->[DeviceSyncOperationKey]{Array(Set((Array(pending.keys)+Array(receipts.keys)+Array(sourceRefreshAttempts.keys)).filter{$0.target==target}))}
    static func presentationReceipt(for key:DeviceSyncOperationKey,pending:[DeviceSyncOperationKey:DeviceSyncIntent],receipts:[DeviceSyncOperationKey:DeviceSyncReceipt],sourceRefreshAttempts:[DeviceSyncOperationKey:DeviceSyncSourceRefreshAttempt])->DeviceSyncReceipt?{receipts[key]}
    static func latestPending(_ values:[DeviceSyncIntent])->[DeviceSyncOperationKey:DeviceSyncIntent]{Dictionary(uniqueKeysWithValues: values.map { ($0.operationKey, $0) })}
    static func latestReceipts(_ values:[DeviceSyncReceipt])->[DeviceSyncOperationKey:DeviceSyncReceipt]{Dictionary(uniqueKeysWithValues: values.map { ($0.operationKey, $0) })}
}

// MARK: - Local action fixture outbox

struct DeviceLocalActionIntent: Codable, Equatable, Sendable { let kind:String; let target:String?; let requestedAt:Date }
struct DeviceLocalActionReceipt: Codable, Equatable, Sendable { let kind:String; let target:String?; let requestedAt:Date; let result:String; let completedAt:Date; let message:String; let pairingSeed:String?; let pairingExpiresAt:Date? }
enum TatwoDeviceLocalActionKind:String { case setPrimary="set-primary", pushVersion="push-version", createPairing="create-pairing" }
struct DeviceLocalActionOutboxStore:Sendable { init(){}; func enqueue(kind:TatwoDeviceLocalActionKind,target:String?=nil)throws->DeviceLocalActionIntent{.init(kind:kind.rawValue,target:target,requestedAt:Date())}; func pendingIntents()throws->[DeviceLocalActionIntent]{[]}; func receipts(kind:TatwoDeviceLocalActionKind)throws->[DeviceLocalActionReceipt]{[]}; func latestReceipt(kind:TatwoDeviceLocalActionKind)throws->DeviceLocalActionReceipt?{nil} }
enum TatwoProductionLayoutLock { static func osNativeStateRoot()->URL { URL(fileURLWithPath:NSTemporaryDirectory()) } }

// MARK: - UI-only remote readiness projection

enum TatwoActiveOriginLeaseReadiness: Equatable { case ready; case verifiedSnapshotUnavailable; case invalidVerifiedSnapshot; case localDeviceIDUnavailable; case activeLeaseUnavailable; case activeLeaseExpired; case splitBrain; case localDeviceIsNotOrigin; var userFacingBlocker:String? { switch self { case .activeLeaseUnavailable:"目前沒有有效的主設備租約。"; case .activeLeaseExpired:"主設備租約已過期。"; case .splitBrain:"偵測到多份主設備租約。"; case .localDeviceIsNotOrigin:"目前主設備不是這台 Mac。"; default:nil } } }
enum TatwoActiveOriginLeaseProjector { static func project(snapshotProvider:any DomainDeviceSnapshotProvider,stateRootURL:URL,now:Date=Date())->TatwoActiveOriginLeaseReadiness { .verifiedSnapshotUnavailable } }
enum ChatRemoteTurnDispatchBlocker:String { case targetLeaseLost="目標設備租約已失效" }
struct DeviceSyncReceiptLoadResult { let receipts:[DeviceSyncReceipt] }
