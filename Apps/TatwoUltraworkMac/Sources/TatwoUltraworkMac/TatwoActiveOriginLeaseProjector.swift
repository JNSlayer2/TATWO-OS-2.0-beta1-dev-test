import Foundation
import TatwoDomainContracts
import TatwoUltraworkCore

enum TatwoActiveOriginLeaseReadiness: Equatable {
    case ready(localDeviceID: String, lease: TatwoAuthorityLeaseV1)
    case verifiedSnapshotUnavailable
    case invalidVerifiedSnapshot(TatwoDomainSnapshotValidationError)
    case localDeviceIDUnavailable
    case activeLeaseUnavailable
    case activeLeaseExpired
    case splitBrain
    case localDeviceIsNotOrigin(holderDeviceID: String)

    var userFacingBlocker: String? {
        switch self {
        case .ready:
            nil
        case .verifiedSnapshotUnavailable:
            "尚未取得可驗證的設備快照。"
        case .invalidVerifiedSnapshot:
            "設備快照未通過完整性驗證。"
        case .localDeviceIDUnavailable:
            "本機設備 ID 尚未可靠落盤。"
        case .activeLeaseUnavailable:
            "目前沒有有效的主設備租約。"
        case .activeLeaseExpired:
            "主設備租約已過期。"
        case .splitBrain:
            "偵測到多份同時有效的主設備租約，已停止派工。"
        case .localDeviceIsNotOrigin:
            "目前主設備不是這台 Mac。"
        }
    }
}

enum TatwoActiveOriginLeaseProjector {
    static func project(
        snapshotProvider: any DomainDeviceSnapshotProvider,
        stateRootURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TatwoActiveOriginLeaseReadiness {
        guard let snapshot = snapshotProvider.verifiedSnapshot() else {
            return .verifiedSnapshotUnavailable
        }
        do {
            // Recheck immutable structure even though the provider contract says
            // "verified". Freshness and split-brain are classified below so the
            // UI can explain the exact fail-closed blocker.
            try TatwoDomainSnapshotValidatorV1.validate(snapshot, now: nil)
        } catch let error as TatwoDomainSnapshotValidationError {
            if error == .splitBrain {
                return .splitBrain
            }
            return .invalidVerifiedSnapshot(error)
        } catch {
            return .verifiedSnapshotUnavailable
        }

        guard let localDeviceID = readPersistedLocalDeviceID(
            stateRootURL: stateRootURL,
            fileManager: fileManager
        ) else {
            return .localDeviceIDUnavailable
        }

        let activeLeases = snapshot.authorityLeases.filter { $0.expiresAt > now }
        guard activeLeases.count <= 1 else {
            return .splitBrain
        }
        guard let lease = activeLeases.first else {
            return snapshot.authorityLeases.isEmpty
                ? .activeLeaseUnavailable
                : .activeLeaseExpired
        }
        guard lease.holderDeviceID == localDeviceID else {
            return .localDeviceIsNotOrigin(holderDeviceID: lease.holderDeviceID)
        }
        return .ready(localDeviceID: localDeviceID, lease: lease)
    }

    static func readPersistedLocalDeviceID(
        stateRootURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let fileURL = stateRootURL.appendingPathComponent(
            TatwoDeviceSnapshotProducer.localDeviceIDFileName,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              data.count <= 256
        else {
            return nil
        }
        let deviceID = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard TatwoLoopPathComponent.isValid(deviceID) else {
            return nil
        }
        return deviceID
    }
}

enum TatwoImmediateRemoteBorrowAuthorizationResult: Equatable {
    case granted(TatwoRemoteSessionGrantV1)
    case blocked(TatwoActiveOriginLeaseReadiness)
}

enum TatwoImmediateRemoteBorrowAuthorizer {
    static func authorize(
        snapshotProvider: any DomainDeviceSnapshotProvider,
        stateRootURL: URL,
        authorizationStore: TatwoRemoteBorrowAuthorizationStore,
        sessionID: String,
        targetDeviceID: String,
        contractID: String,
        now: Date = Date()
    ) throws -> TatwoImmediateRemoteBorrowAuthorizationResult {
        let readiness = TatwoActiveOriginLeaseProjector.project(
            snapshotProvider: snapshotProvider,
            stateRootURL: stateRootURL,
            now: now
        )
        guard case .ready = readiness else {
            return .blocked(readiness)
        }
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: sessionID,
            targetDeviceID: targetDeviceID,
            contractID: contractID,
            risk: .lowRisk,
            now: now
        )
        return .granted(grant)
    }
}
