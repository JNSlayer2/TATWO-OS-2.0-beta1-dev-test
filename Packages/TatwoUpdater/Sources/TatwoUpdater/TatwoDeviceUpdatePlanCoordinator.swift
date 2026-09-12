import Foundation

public final class TatwoDeviceUpdatePlanCoordinator:
    TatwoDeviceUpdatePlanCommandPort,
    TatwoDeviceUpdatePlanSnapshotProvider
{
    private let persistence: any TatwoDeviceUpdatePlanPersistencePort
    private var plansByID: [String: TatwoDeviceUpdatePlanV1] = [:]

    public init(persistence: any TatwoDeviceUpdatePlanPersistencePort) throws {
        self.persistence = persistence
        for record in try persistence.loadValidatedRecords() {
            try applyPersistedEvent(record.event)
        }
    }

    public func createPlan(
        _ request: TatwoCreateDeviceUpdatePlanRequestV1
    ) throws -> TatwoDeviceUpdatePlanV1 {
        guard !request.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TatwoDeviceUpdatePlanError.emptyPlanID
        }
        guard !request.domainID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TatwoDeviceUpdatePlanError.emptyDomainID
        }
        guard !request.selectedDevices.isEmpty else {
            throw TatwoDeviceUpdatePlanError.emptyDeviceSelection
        }
        guard request.maximumHeartbeatAgeSeconds > 0 else {
            throw TatwoDeviceUpdatePlanError.invalidHeartbeatAge
        }
        guard request.channel == request.artifact.channel else {
            throw TatwoDeviceUpdatePlanError.artifactChannelMismatch
        }
        guard plansByID[request.planID] == nil else {
            throw TatwoDeviceUpdatePlanError.planAlreadyExists(request.planID)
        }

        let ordered = try validateAndOrder(request.selectedDevices)
        let plan = TatwoDeviceUpdatePlanV1(
            planID: request.planID,
            domainID: request.domainID,
            channel: request.channel,
            artifact: request.artifact,
            createdAt: request.createdAt,
            approvedAt: nil,
            maximumHeartbeatAgeSeconds: request.maximumHeartbeatAgeSeconds,
            status: .awaitingApproval,
            steps: ordered.enumerated().map { offset, snapshot in
                TatwoDeviceUpdateStepV1(
                    deviceID: snapshot.deviceID,
                    role: snapshot.role,
                    executionOrder: offset,
                    observedVersion: snapshot.currentVersion,
                    status: .awaitingApproval,
                    skipReason: .userApprovalRequired,
                    lastPreflightAt: nil,
                    detail: "One explicit user approval is required for this device batch"
                )
            }
        )
        try persist(
            .init(kind: .created, plan: plan, deviceID: nil, observedAt: request.createdAt)
        )
        return plan
    }

    public func approvePlan(
        _ request: TatwoApproveDeviceUpdatePlanRequestV1
    ) throws -> TatwoDeviceUpdatePlanV1 {
        guard request.userApproved else {
            throw TatwoDeviceUpdatePlanError.userApprovalRequired
        }
        guard let current = plansByID[request.planID] else {
            throw TatwoDeviceUpdatePlanError.planNotFound(request.planID)
        }
        guard current.approvedAt == nil else {
            throw TatwoDeviceUpdatePlanError.planAlreadyApproved(request.planID)
        }

        let snapshots = try snapshotsByID(
            request.deviceSnapshots,
            matching: current.steps
        )
        let updatedSteps = current.steps.map { step in
            preflight(
                step: step,
                snapshot: snapshots[step.deviceID]!,
                plan: current,
                observedAt: request.observedAt
            )
        }
        let updated = replacing(
            current,
            approvedAt: request.observedAt,
            steps: updatedSteps
        )
        try persist(
            .init(
                kind: .approved,
                plan: updated,
                deviceID: nil,
                observedAt: request.observedAt
            )
        )
        return updated
    }

    public func revalidateDevice(
        planID: String,
        snapshot: TatwoDeviceUpdatePreflightSnapshotV1,
        observedAt: Date
    ) throws -> TatwoDeviceUpdatePlanV1 {
        guard let current = plansByID[planID] else {
            throw TatwoDeviceUpdatePlanError.planNotFound(planID)
        }
        guard current.approvedAt != nil else {
            throw TatwoDeviceUpdatePlanError.userApprovalRequired
        }
        guard let index = current.steps.firstIndex(where: { $0.deviceID == snapshot.deviceID }) else {
            throw TatwoDeviceUpdatePlanError.deviceNotFound(snapshot.deviceID)
        }
        let existing = current.steps[index]
        guard existing.status != .installed else {
            throw TatwoDeviceUpdatePlanError.invalidDeviceTransition(snapshot.deviceID)
        }
        guard existing.role == snapshot.role else {
            throw TatwoDeviceUpdatePlanError.deviceRoleChanged(snapshot.deviceID)
        }

        var steps = current.steps
        steps[index] = preflight(
            step: existing,
            snapshot: snapshot,
            plan: current,
            observedAt: observedAt
        )
        let updated = replacing(current, approvedAt: current.approvedAt, steps: steps)
        try persist(
            .init(
                kind: .devicePreflighted,
                plan: updated,
                deviceID: snapshot.deviceID,
                observedAt: observedAt
            )
        )
        return updated
    }

    public func recordDeviceOutcome(
        planID: String,
        deviceID: String,
        outcome: TatwoDeviceUpdateExecutionOutcomeV1,
        detail: String,
        observedAt: Date
    ) throws -> TatwoDeviceUpdatePlanV1 {
        guard let current = plansByID[planID] else {
            throw TatwoDeviceUpdatePlanError.planNotFound(planID)
        }
        guard let index = current.steps.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw TatwoDeviceUpdatePlanError.deviceNotFound(deviceID)
        }
        let existing = current.steps[index]
        guard existing.status == .eligible else {
            throw TatwoDeviceUpdatePlanError.invalidDeviceTransition(deviceID)
        }

        var steps = current.steps
        steps[index] = TatwoDeviceUpdateStepV1(
            deviceID: existing.deviceID,
            role: existing.role,
            executionOrder: existing.executionOrder,
            observedVersion: outcome == .installed
                ? current.artifact.version
                : existing.observedVersion,
            status: outcome == .installed ? .installed : .failed,
            skipReason: .none,
            lastPreflightAt: existing.lastPreflightAt,
            detail: detail
        )
        let updated = replacing(current, approvedAt: current.approvedAt, steps: steps)
        try persist(
            .init(
                kind: .deviceOutcomeRecorded,
                plan: updated,
                deviceID: deviceID,
                observedAt: observedAt
            )
        )
        return updated
    }

    public func deviceUpdatePlan(planID: String) -> TatwoDeviceUpdatePlanV1? {
        plansByID[planID]
    }

    public func allDeviceUpdatePlans() -> [TatwoDeviceUpdatePlanV1] {
        plansByID.values.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.planID < $1.planID
        }
    }

    public func nextEligibleDeviceID(planID: String) -> String? {
        plansByID[planID]?.steps
            .filter { $0.status == .eligible }
            .min { $0.executionOrder < $1.executionOrder }?
            .deviceID
    }

    private func validateAndOrder(
        _ snapshots: [TatwoDeviceUpdatePreflightSnapshotV1]
    ) throws -> [TatwoDeviceUpdatePreflightSnapshotV1] {
        var seen = Set<String>()
        for snapshot in snapshots {
            guard seen.insert(snapshot.deviceID).inserted else {
                throw TatwoDeviceUpdatePlanError.duplicateDeviceID(snapshot.deviceID)
            }
        }
        guard snapshots.filter({ $0.role == .primary }).count <= 1 else {
            throw TatwoDeviceUpdatePlanError.multiplePrimaryDevices
        }
        return snapshots.sorted {
            if $0.role != $1.role {
                return $0.role == .secondary
            }
            return $0.deviceID < $1.deviceID
        }
    }

    private func snapshotsByID(
        _ snapshots: [TatwoDeviceUpdatePreflightSnapshotV1],
        matching steps: [TatwoDeviceUpdateStepV1]
    ) throws -> [String: TatwoDeviceUpdatePreflightSnapshotV1] {
        let ordered = try validateAndOrder(snapshots)
        guard Set(ordered.map(\.deviceID)) == Set(steps.map(\.deviceID)) else {
            throw TatwoDeviceUpdatePlanError.deviceSetMismatch
        }
        let result = Dictionary(uniqueKeysWithValues: ordered.map { ($0.deviceID, $0) })
        for step in steps where result[step.deviceID]?.role != step.role {
            throw TatwoDeviceUpdatePlanError.deviceRoleChanged(step.deviceID)
        }
        return result
    }

    private func preflight(
        step: TatwoDeviceUpdateStepV1,
        snapshot: TatwoDeviceUpdatePreflightSnapshotV1,
        plan: TatwoDeviceUpdatePlanV1,
        observedAt: Date
    ) -> TatwoDeviceUpdateStepV1 {
        let decision: (TatwoDeviceUpdateStepStatusV1, TatwoDeviceUpdateSkipReasonV1, String)
        if !snapshot.isOnline {
            decision = (.skipped, .offline, "Device is offline; retry requires a fresh preflight")
        } else if snapshot.lastSeenAt == nil
                    || snapshot.lastSeenAt! > observedAt
                    || observedAt.timeIntervalSince(snapshot.lastSeenAt!)
                        > plan.maximumHeartbeatAgeSeconds
        {
            decision = (
                .skipped,
                .staleHeartbeat,
                "Heartbeat is missing, future-dated, or older than the plan freshness window"
            )
        } else if !snapshot.isHealthy {
            decision = (.skipped, .unhealthy, "Device health is not eligible for activation")
        } else if snapshot.enrolledChannel != plan.channel {
            decision = (.skipped, .channelMismatch, "Device update channel does not match the plan")
        } else if snapshot.schemaVersion != plan.artifact.schemaVersion {
            decision = (.skipped, .schemaMismatch, "Device schema is incompatible with the artifact")
        } else if snapshot.protocolVersion != plan.artifact.protocolVersion {
            decision = (
                .skipped,
                .protocolMismatch,
                "Device protocol is incompatible with the artifact"
            )
        } else if !snapshot.hasVerifiedRollbackBundle {
            decision = (
                .skipped,
                .rollbackUnavailable,
                "A verified rollback bundle is required before activation"
            )
        } else if snapshot.currentVersion >= plan.artifact.version {
            decision = (.skipped, .alreadyCurrent, "Device is already at or beyond the target version")
        } else {
            decision = (
                .eligible,
                .none,
                "Independent device preflight passed; execution remains ordered secondary-first"
            )
        }

        return TatwoDeviceUpdateStepV1(
            deviceID: step.deviceID,
            role: step.role,
            executionOrder: step.executionOrder,
            observedVersion: snapshot.currentVersion,
            status: decision.0,
            skipReason: decision.1,
            lastPreflightAt: observedAt,
            detail: decision.2
        )
    }

    private func replacing(
        _ plan: TatwoDeviceUpdatePlanV1,
        approvedAt: Date?,
        steps: [TatwoDeviceUpdateStepV1]
    ) -> TatwoDeviceUpdatePlanV1 {
        TatwoDeviceUpdatePlanV1(
            planID: plan.planID,
            domainID: plan.domainID,
            channel: plan.channel,
            artifact: plan.artifact,
            createdAt: plan.createdAt,
            approvedAt: approvedAt,
            maximumHeartbeatAgeSeconds: plan.maximumHeartbeatAgeSeconds,
            status: status(approvedAt: approvedAt, steps: steps),
            steps: steps
        )
    }

    private func status(
        approvedAt: Date?,
        steps: [TatwoDeviceUpdateStepV1]
    ) -> TatwoDeviceUpdatePlanStatusV1 {
        guard approvedAt != nil else {
            return .awaitingApproval
        }
        if steps.contains(where: { $0.status == .failed }) {
            return .failed
        }
        let eligible = steps.filter { $0.status == .eligible }.count
        let installed = steps.filter { $0.status == .installed }.count
        let skipped = steps.filter { $0.status == .skipped }.count

        if installed + skipped == steps.count {
            return installed > 0 ? .completed : .blocked
        }
        if installed > 0 {
            return .inProgress
        }
        if eligible == steps.count {
            return .ready
        }
        if eligible > 0 {
            return .partiallyEligible
        }
        return .blocked
    }

    private func persist(_ event: TatwoDeviceUpdatePlanEventV1) throws {
        do {
            _ = try persistence.append(event)
            try applyPersistedEvent(event)
        } catch let error as TatwoDeviceUpdatePlanError {
            throw error
        } catch {
            throw TatwoDeviceUpdatePlanError.corruptPersistence(String(describing: error))
        }
    }

    private func applyPersistedEvent(_ event: TatwoDeviceUpdatePlanEventV1) throws {
        let plan = event.plan
        switch event.kind {
        case .created:
            guard plansByID[plan.planID] == nil else {
                throw TatwoDeviceUpdatePlanError.planAlreadyExists(plan.planID)
            }
        case .approved, .devicePreflighted, .deviceOutcomeRecorded:
            guard let previous = plansByID[plan.planID] else {
                throw TatwoDeviceUpdatePlanError.planNotFound(plan.planID)
            }
            guard previous.domainID == plan.domainID,
                  previous.channel == plan.channel,
                  previous.artifact == plan.artifact,
                  previous.createdAt == plan.createdAt,
                  previous.steps.map(\.deviceID) == plan.steps.map(\.deviceID),
                  previous.steps.map(\.role) == plan.steps.map(\.role),
                  previous.steps.map(\.executionOrder) == plan.steps.map(\.executionOrder)
            else {
                throw TatwoDeviceUpdatePlanError.corruptPersistence(plan.planID)
            }
        }
        plansByID[plan.planID] = plan
    }
}
