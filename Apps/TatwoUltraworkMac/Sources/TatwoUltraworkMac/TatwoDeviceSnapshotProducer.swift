import CryptoKit
import Foundation
import os
import TatwoDeviceSyncCore
import TatwoDomainContracts

/// Thread-safe relay carrying the producer's latest healthy register receipt
/// hash into the `snapshotProducerReceiptSHA256` closure that
/// `TatwoDeviceSyncCore` captures at init time. `persistVerifiedSnapshot`
/// takes no hash parameter; the core reads it through that closure, so the
/// producer publishes the real value here and the core pulls it on demand.
final class TatwoSnapshotProducerReceiptHashRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}

/// Periodically registers this Mac in the domain Device Sync core (which also
/// refreshes its heartbeat) and, when the register receipt is healthy,
/// publishes the SHA-256 of that receipt's canonical JSON as the producer
/// receipt digest before persisting a verified snapshot generation.
///
/// Never spawns processes. All failures are fail-soft: the most recent error
/// string is retained for UI display and the producer keeps ticking.
@MainActor
final class TatwoDeviceSnapshotProducer {
    nonisolated static let heartbeatInterval: TimeInterval = 60
    nonisolated static let localDeviceIDFileName = "local-device-id"

    private static let logger = Logger(
        subsystem: "ai.tatwo.ultrawork",
        category: "device-snapshot-producer"
    )

    private let syncCore: TatwoDeviceSyncCore
    private let domainID: String
    private let deviceDisplayName: String
    private let deviceKind: TatwoDomainDeviceKindV1
    private let receiptHashSink: (String?) -> Void
    private let now: () -> Date
    private var timer: Timer?
    private var firstRegisteredAt: Date?

    /// Stable per-machine identifier persisted at
    /// `stateRootURL/local-device-id`. Falls back to a session-scoped UUID
    /// when the file cannot be read or written.
    let localDeviceID: String
    private(set) var lastErrorDescription: String?

    init(
        syncCore: TatwoDeviceSyncCore,
        deviceDisplayName: String,
        deviceKind: TatwoDomainDeviceKindV1,
        stateRootURL: URL,
        domainID: String,
        receiptHashSink: @escaping (String?) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.syncCore = syncCore
        self.domainID = domainID
        self.deviceDisplayName = deviceDisplayName
        self.deviceKind = deviceKind
        self.receiptHashSink = receiptHashSink
        self.now = now
        let loaded = Self.loadOrCreateLocalDeviceID(stateRootURL: stateRootURL)
        self.localDeviceID = loaded.deviceID
        self.lastErrorDescription = loaded.failureDetail
        if let failureDetail = loaded.failureDetail {
            Self.logger.error("\(failureDetail, privacy: .public)")
        }
    }

    /// Runs one tick immediately, then repeats every 60 seconds until
    /// `stop()` is called.
    func start() {
        stop()
        tick()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let observedAt = now()
        let correlationID = "device-snapshot-producer-\(UUID().uuidString)"
        let registeredAt = firstRegisteredAt ?? observedAt
        firstRegisteredAt = registeredAt
        let device = TatwoDomainDeviceV1(
            id: localDeviceID,
            domainID: domainID,
            displayName: deviceDisplayName,
            kind: deviceKind,
            connectionState: .connected,
            schemaVersion: 1,
            protocolVersion: 1,
            registeredAt: registeredAt,
            lastHeartbeatAt: observedAt
        )
        let registerReceipt = syncCore.registerDevice(
            TatwoRegisterDeviceRequestV1(
                device: device,
                correlationID: correlationID
            )
        )
        guard registerReceipt.status == .healthy else {
            recordError(
                "registerDevice \(registerReceipt.errorKind): "
                    + registerReceipt.detail
            )
            return
        }
        guard let receiptHash = Self.sha256HexOfCanonicalJSON(registerReceipt)
        else {
            recordError("register receipt could not be canonically hashed")
            return
        }
        receiptHashSink(receiptHash)
        let persistReceipt = syncCore.persistVerifiedSnapshot(
            correlationID: correlationID
        )
        if persistReceipt.status == .healthy {
            lastErrorDescription = nil
        } else {
            recordError(
                "persistVerifiedSnapshot \(persistReceipt.errorKind): "
                    + persistReceipt.detail
            )
        }
    }

    private func recordError(_ description: String) {
        lastErrorDescription = description
        Self.logger.error("\(description, privacy: .public)")
    }

    /// Lowercase hex SHA-256 of the receipt's canonical JSON (sorted keys,
    /// ISO-8601 dates, unescaped slashes) — the same canonical form the
    /// coordinator transports use for wire payloads.
    nonisolated static func sha256HexOfCanonicalJSON(
        _ receipt: TatwoSyncHealthReceiptV1
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(receipt) else {
            return nil
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func loadOrCreateLocalDeviceID(
        stateRootURL: URL
    ) -> (deviceID: String, failureDetail: String?) {
        let fileURL = stateRootURL.appendingPathComponent(
            localDeviceIDFileName,
            isDirectory: false
        )
        if let data = try? Data(contentsOf: fileURL) {
            let stored = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty, stored.utf8.count <= 256 {
                return (stored, nil)
            }
        }
        let fresh = UUID().uuidString
        do {
            try FileManager.default.createDirectory(
                at: stateRootURL,
                withIntermediateDirectories: true
            )
            try Data(fresh.utf8).write(to: fileURL, options: .atomic)
            return (fresh, nil)
        } catch {
            return (
                fresh,
                "local-device-id persistence failed at \(fileURL.path); "
                    + "using a session-scoped device id"
            )
        }
    }
}
