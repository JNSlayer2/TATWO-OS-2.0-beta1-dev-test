import Foundation
import TatwoModuleContracts
import TatwoDeploymentPrimitives

public final class TatwoBootstrapCore: TatwoBootstrapCommandPort {
    private let activationPort: any TatwoBootstrapDeploymentPort
    private let resetPort: any TatwoModuleResetPort
    private let makeReceiptID: () -> String
    private let now: () -> Date

    public init(
        activationPort: any TatwoBootstrapDeploymentPort,
        resetPort: any TatwoModuleResetPort,
        receiptID: @escaping () -> String = { UUID().uuidString },
        now: @escaping () -> Date = Date.init
    ) {
        self.activationPort = activationPort
        self.resetPort = resetPort
        self.makeReceiptID = receiptID
        self.now = now
    }

    public func plan(_ request: TatwoBootstrapPlanRequestV1) -> TatwoDeploymentReceipt {
        switch resolvePlan(manifests: request.manifests, requested: request.requestedModuleIDs) {
        case let .success(ordered):
            let manifestsByID = Dictionary(
                uniqueKeysWithValues: request.manifests.map { ($0.moduleID, $0) }
            )
            let steps = ordered.compactMap { moduleID -> TatwoDeploymentStepReceiptV1? in
                guard let manifest = manifestsByID[moduleID] else {
                    return nil
                }
                return TatwoDeploymentStepReceiptV1(
                    moduleID: moduleID,
                    step: TatwoBootstrapCommandOperationV1.plan.rawValue,
                    outcome: .succeeded,
                    detail: "Dependency and reset policy validated",
                    resetArtifacts: manifest.reset.resettableArtifacts
                )
            }
            return receipt(
                operation: .plan,
                correlationID: request.correlationID,
                outcome: .succeeded,
                orderedModuleIDs: ordered,
                steps: steps,
                detail: "Dependency plan resolved"
            )
        case let .failure(failure):
            return receipt(
                operation: .plan,
                correlationID: request.correlationID,
                outcome: .failed,
                failureCode: failure.code,
                detail: failure.detail
            )
        }
    }

    public func apply(_ request: TatwoBootstrapApplyRequestV1) -> TatwoDeploymentReceipt {
        execute(
            operation: .apply,
            plan: request.plan,
            candidates: request.candidates,
            selectedModuleIDs: request.plan.orderedModuleIDs,
            correlationID: request.correlationID
        )
    }

    public func repair(_ request: TatwoBootstrapRepairRequestV1) -> TatwoDeploymentReceipt {
        execute(
            operation: .repair,
            plan: request.plan,
            candidates: request.candidates,
            selectedModuleIDs: request.moduleIDs,
            correlationID: request.correlationID
        )
    }

    public func resetModule(
        _ request: TatwoBootstrapResetModuleRequestV1
    ) -> TatwoDeploymentReceipt {
        let effectRequest = TatwoModuleResetEffectRequestV1(manifest: request.manifest)
        do {
            let effect = try resetPort.reset(effectRequest)
            let step = TatwoDeploymentStepReceiptV1(
                moduleID: request.manifest.moduleID,
                step: TatwoBootstrapCommandOperationV1.resetModule.rawValue,
                outcome: .succeeded,
                detail: effect.detail,
                resetArtifacts: effect.resetArtifacts
            )
            return receipt(
                operation: .resetModule,
                correlationID: request.correlationID,
                outcome: .succeeded,
                orderedModuleIDs: [request.manifest.moduleID],
                steps: [step],
                detail: "Reset completed for resettable artifacts only; user data and domain ledger preserved"
            )
        } catch {
            return receipt(
                operation: .resetModule,
                correlationID: request.correlationID,
                outcome: .failed,
                failureCode: .resetFailed,
                orderedModuleIDs: [request.manifest.moduleID],
                detail: "Reset failed: \(error)"
            )
        }
    }

    public func doctor(_ request: TatwoBootstrapDoctorRequestV1) -> TatwoDeploymentReceipt {
        let allModuleIDs = request.manifests.map(\.moduleID)
        switch resolvePlan(manifests: request.manifests, requested: allModuleIDs) {
        case let .failure(failure):
            return receipt(
                operation: .doctor,
                correlationID: request.correlationID,
                outcome: .failed,
                failureCode: failure.code,
                detail: failure.detail
            )
        case let .success(ordered):
            let snapshots = Dictionary(uniqueKeysWithValues: request.snapshots.map { ($0.moduleID, $0) })
            let unhealthy = ordered.first { snapshots[$0]?.status != .healthy }
            if let unhealthy {
                return receipt(
                    operation: .doctor,
                    correlationID: request.correlationID,
                    outcome: .failed,
                    failureCode: .unhealthyModule,
                    orderedModuleIDs: ordered,
                    detail: "Module health is not healthy: \(unhealthy.rawValue)"
                )
            }
            return receipt(
                operation: .doctor,
                correlationID: request.correlationID,
                outcome: .succeeded,
                orderedModuleIDs: ordered,
                detail: "All module snapshots are healthy"
            )
        }
    }

    private func execute(
        operation: TatwoBootstrapCommandOperationV1,
        plan: TatwoBootstrapPlanV1,
        candidates: [TatwoBootstrapBundleCandidateV1],
        selectedModuleIDs: [TatwoModuleIDV1],
        correlationID: String
    ) -> TatwoDeploymentReceipt {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.moduleID, $0) })
        let selected = Set(selectedModuleIDs)
        let ordered = plan.orderedModuleIDs.filter(selected.contains)
        var steps: [TatwoDeploymentStepReceiptV1] = []
        var currentOperation: TatwoBundleOperationKindV1 = .stage
        var rollbackRequired = false

        for moduleID in ordered {
            guard let candidate = candidateByID[moduleID] else {
                return receipt(
                    operation: operation,
                    correlationID: correlationID,
                    outcome: .failed,
                    failureCode: .missingCandidate,
                    orderedModuleIDs: ordered,
                    steps: steps,
                    detail: "Missing bundle candidate for \(moduleID.rawValue)"
                )
            }

            do {
                currentOperation = .stage
                let stage = try activationPort.stage(candidate.stage)
                steps.append(step(stage))
                guard stage.outcome == .succeeded else {
                    return failedExecution(
                        operation: operation,
                        correlationID: correlationID,
                        code: .stageFailed,
                        ordered: ordered,
                        steps: steps,
                        detail: stage.detail
                    )
                }

                currentOperation = .verify
                let verification = try activationPort.verify(candidate.verify)
                steps.append(step(verification))
                guard verification.outcome == .succeeded else {
                    return failedExecution(
                        operation: operation,
                        correlationID: correlationID,
                        code: .verificationFailed,
                        ordered: ordered,
                        steps: steps,
                        detail: verification.detail
                    )
                }

                currentOperation = .archiveCurrent
                let archive = try activationPort.archiveCurrent(candidate.archiveCurrent)
                steps.append(step(archive))
                guard archive.outcome == .succeeded else {
                    return failedExecution(
                        operation: operation,
                        correlationID: correlationID,
                        code: .archiveFailed,
                        ordered: ordered,
                        steps: steps,
                        detail: archive.detail
                    )
                }

                currentOperation = .atomicSwap
                rollbackRequired = true
                let swap = try activationPort.atomicSwap(candidate.atomicSwap)
                steps.append(step(swap))
                guard swap.outcome == .succeeded else {
                    return rollbackAfterMutationFailure(
                        operation: operation,
                        correlationID: correlationID,
                        originalCode: .atomicSwapFailed,
                        ordered: ordered,
                        steps: steps,
                        candidate: candidate,
                        detail: swap.detail
                    )
                }

                currentOperation = .healthCheck
                let health = try activationPort.healthCheck(candidate.healthCheck)
                steps.append(step(health))
                guard health.outcome == .succeeded else {
                    return rollbackAfterMutationFailure(
                        operation: operation,
                        correlationID: correlationID,
                        originalCode: .healthCheckFailed,
                        ordered: ordered,
                        steps: steps,
                        candidate: candidate,
                        detail: health.detail
                    )
                }
                rollbackRequired = false
            } catch {
                if rollbackRequired {
                    return rollbackAfterMutationFailure(
                        operation: operation,
                        correlationID: correlationID,
                        originalCode: failureCode(for: currentOperation),
                        ordered: ordered,
                        steps: steps,
                        candidate: candidate,
                        detail: "Deployment primitive threw after activation may have mutated the bundle: \(error)"
                    )
                }
                return failedExecution(
                    operation: operation,
                    correlationID: correlationID,
                    code: failureCode(for: currentOperation),
                    ordered: ordered,
                    steps: steps,
                    detail: "Deployment primitive failed: \(error)"
                )
            }
        }

        return receipt(
            operation: operation,
            correlationID: correlationID,
            outcome: .succeeded,
            orderedModuleIDs: ordered,
            steps: steps,
            detail: "Bundle deployment completed without domain authority or user-data effects"
        )
    }

    private func rollbackAfterMutationFailure(
        operation: TatwoBootstrapCommandOperationV1,
        correlationID: String,
        originalCode: TatwoDeploymentFailureCodeV1,
        ordered: [TatwoModuleIDV1],
        steps: [TatwoDeploymentStepReceiptV1],
        candidate: TatwoBootstrapBundleCandidateV1,
        detail: String
    ) -> TatwoDeploymentReceipt {
        var recoveredSteps = steps
        do {
            let rollback = try activationPort.rollbackBundle(candidate.rollbackBundle)
            recoveredSteps.append(step(rollback))
            guard rollback.outcome == .succeeded else {
                return failedExecution(
                    operation: operation,
                    correlationID: correlationID,
                    code: .rollbackFailed,
                    ordered: ordered,
                    steps: recoveredSteps,
                    detail: "\(detail); bundle-only rollback reported failure: \(rollback.detail)"
                )
            }
            return failedExecution(
                operation: operation,
                correlationID: correlationID,
                code: originalCode,
                ordered: ordered,
                steps: recoveredSteps,
                detail: "\(detail); previous verified bundle restored"
            )
        } catch {
            return failedExecution(
                operation: operation,
                correlationID: correlationID,
                code: .rollbackFailed,
                ordered: ordered,
                steps: recoveredSteps,
                detail: "\(detail); bundle-only rollback threw: \(error)"
            )
        }
    }

    private func resolvePlan(
        manifests: [TatwoModuleManifestV1],
        requested: [TatwoModuleIDV1]
    ) -> Result<[TatwoModuleIDV1], PlanFailure> {
        let grouped = Dictionary(grouping: manifests, by: \.moduleID)
        if let duplicate = grouped.first(where: { $0.value.count > 1 })?.key {
            return .failure(
                PlanFailure(code: .invalidPlan, detail: "Duplicate manifest: \(duplicate.rawValue)")
            )
        }
        let manifestByID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.moduleID, $0) })
        let roots = requested.isEmpty ? manifests.map(\.moduleID).sorted() : requested
        var ordered: [TatwoModuleIDV1] = []
        var permanent = Set<TatwoModuleIDV1>()
        var temporary = Set<TatwoModuleIDV1>()

        func visit(_ moduleID: TatwoModuleIDV1) -> PlanFailure? {
            if permanent.contains(moduleID) {
                return nil
            }
            if temporary.contains(moduleID) {
                return PlanFailure(
                    code: .dependencyCycle,
                    detail: "Dependency cycle includes \(moduleID.rawValue)"
                )
            }
            guard let manifest = manifestByID[moduleID] else {
                return PlanFailure(
                    code: .missingDependency,
                    detail: "Missing dependency manifest: \(moduleID.rawValue)"
                )
            }

            temporary.insert(moduleID)
            for dependency in manifest.dependencies.sorted(by: { $0.moduleID < $1.moduleID }) {
                if
                    let requiredVersion = dependency.minimumVersion,
                    let availableVersion = manifestByID[dependency.moduleID]?.version,
                    availableVersion < requiredVersion
                {
                    return PlanFailure(
                        code: .incompatibleDependencyVersion,
                        detail: "Dependency \(dependency.moduleID.rawValue) requires \(requiredVersion) but found \(availableVersion)"
                    )
                }
                if let failure = visit(dependency.moduleID) {
                    return failure
                }
            }
            temporary.remove(moduleID)
            permanent.insert(moduleID)
            ordered.append(moduleID)
            return nil
        }

        for root in roots {
            if let failure = visit(root) {
                return .failure(failure)
            }
        }
        return .success(ordered)
    }

    private func step(_ receipt: TatwoBundleOperationReceiptV1) -> TatwoDeploymentStepReceiptV1 {
        TatwoDeploymentStepReceiptV1(
            moduleID: receipt.moduleID,
            step: receipt.operation.rawValue,
            outcome: receipt.outcome == .succeeded ? .succeeded : .failed,
            detail: receipt.detail,
            bundleIsolationEvidence: receipt.isolationEvidence
        )
    }

    private func failureCode(
        for operation: TatwoBundleOperationKindV1
    ) -> TatwoDeploymentFailureCodeV1 {
        switch operation {
        case .stage: .stageFailed
        case .verify: .verificationFailed
        case .archiveCurrent: .archiveFailed
        case .atomicSwap: .atomicSwapFailed
        case .healthCheck: .healthCheckFailed
        case .rollbackBundle: .rollbackFailed
        }
    }

    private func failedExecution(
        operation: TatwoBootstrapCommandOperationV1,
        correlationID: String,
        code: TatwoDeploymentFailureCodeV1,
        ordered: [TatwoModuleIDV1],
        steps: [TatwoDeploymentStepReceiptV1],
        detail: String
    ) -> TatwoDeploymentReceipt {
        receipt(
            operation: operation,
            correlationID: correlationID,
            outcome: .failed,
            failureCode: code,
            orderedModuleIDs: ordered,
            steps: steps,
            detail: detail
        )
    }

    private func receipt(
        operation: TatwoBootstrapCommandOperationV1,
        correlationID: String,
        outcome: TatwoDeploymentReceiptOutcomeV1,
        failureCode: TatwoDeploymentFailureCodeV1? = nil,
        orderedModuleIDs: [TatwoModuleIDV1] = [],
        steps: [TatwoDeploymentStepReceiptV1] = [],
        detail: String
    ) -> TatwoDeploymentReceipt {
        TatwoDeploymentReceiptV1(
            receiptID: makeReceiptID(),
            operation: operation,
            correlationID: correlationID,
            createdAt: now(),
            outcome: outcome,
            failureCode: failureCode,
            orderedModuleIDs: orderedModuleIDs,
            steps: steps,
            detail: detail
        )
    }
}

private struct PlanFailure: Error {
    let code: TatwoDeploymentFailureCodeV1
    let detail: String
}
