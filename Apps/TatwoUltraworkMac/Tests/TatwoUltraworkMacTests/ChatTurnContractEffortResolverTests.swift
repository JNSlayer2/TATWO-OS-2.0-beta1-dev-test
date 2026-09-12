import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ChatTurnContractEffortResolverTests: XCTestCase {
    func testCanonicalSingleModelFallbackUsesOnlyExactIssuedIdentitySlot() throws {
        let contract = try WorkOSFactory.projectContract(
            mode: .s,
            scenarioProfileID: "coding",
            routeBindingOverride: .init(
                primaryModelID: "gpt-5.6-terra", secondaryModelID: nil))
        XCTAssertTrue(contract.loopGovernorDecision.activatedBindings.isEmpty)
        let lead = try XCTUnwrap(contract.identityBindings.first {
            $0.identity == .lead && $0.modelID == "gpt-5.6-terra"
        })
        for slot in [lead.sourceSlotID, "unissued-slot"] {
            let resolved = ChatTurnContractEffortResolver.resolve(
                route: try route("gpt-5.6-terra"),
                phase: .loops,
                contract: contract,
                uiSelectedEffort: .medium,
                canonicalSourceSlotID: slot)
            XCTAssertEqual(resolved.canDispatch, slot == lead.sourceSlotID)
            if slot == lead.sourceSlotID {
                XCTAssertEqual(resolved.contractBindingID, lead.sourceSlotID)
                XCTAssertEqual(resolved.forwardedEffort, .medium)
            } else {
                XCTAssertNil(resolved.contractBindingID)
                XCTAssertNil(resolved.forwardedEffort)
            }
        }
    }

    func testCanonicalDispatchKeepsIssuedPlanSlotAfterExecutionPhaseAdvances() throws {
        let contract = try exactContract()
        let binding = try XCTUnwrap(
            contract.loopGovernorDecision.activatedBindings.first {
                $0.phase == .plan && $0.boundModelIDs.contains("gpt-5.6-sol")
            })
        let resolved = ChatTurnContractEffortResolver.resolve(
            route: try route("gpt-5.6-sol"),
            phase: .loops,
            contract: contract,
            uiSelectedEffort: .low,
            canonicalSourceSlotID: binding.id)

        XCTAssertEqual(resolved.phase, .loops)
        XCTAssertEqual(resolved.contractBindingID, binding.id)
        XCTAssertEqual(resolved.requestedEffort, binding.reasoningEffort)
        XCTAssertTrue(resolved.canDispatch)
    }

    func testCanonicalSlotCannotFallbackToUIEffortOrAnotherModelBinding() throws {
        let contract = try exactContract()
        let lunaSlot = try XCTUnwrap(
            contract.loopGovernorDecision.activatedBindings.first {
                $0.boundModelIDs.contains("gpt-5.6-luna")
            })
        for slotID in ["not-issued", lunaSlot.id] {
            let resolved = ChatTurnContractEffortResolver.resolve(
                route: try route("gpt-5.6-sol"),
                phase: .loops,
                contract: contract,
                uiSelectedEffort: .high,
                canonicalSourceSlotID: slotID)
            XCTAssertFalse(resolved.canDispatch, slotID)
            XCTAssertNil(resolved.contractBindingID, slotID)
            XCTAssertNil(resolved.forwardedEffort, slotID)
        }
    }

    func testContractBindingWinsOverUIEffortForCanonicalRouteAndPhase() throws {
        let contract = try exactContract()
        let luna = try route("gpt-5.6-luna")

        let resolved = ChatTurnContractEffortResolver.resolve(
            route: luna,
            phase: .loops,
            contract: contract,
            uiSelectedEffort: .low)

        XCTAssertEqual(resolved.contractID, contract.contractID)
        XCTAssertEqual(
            resolved.contractBindingID,
            "general-xxl-exact-loops-sub-luna")
        XCTAssertEqual(resolved.requestedEffort, .xhigh)
        XCTAssertEqual(resolved.forwardedEffort, .xhigh)
        XCTAssertEqual(resolved.effortOutcome, .forwardedAwaitingProvider)
        XCTAssertTrue(resolved.canDispatch)
    }

    func testMutableScenarioBookCannotOverrideAlreadyIssuedContractBinding() throws {
        var mutableBook = TatwoScenarioConfigDefaults.book
        let contract = try exactContract(book: mutableBook)
        let scenarioIndex = try XCTUnwrap(
            mutableBook.scenarios.firstIndex {
                $0.id == TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID
            })
        var modeConfig = try XCTUnwrap(
            mutableBook.scenarios[scenarioIndex].modeConfigs[.xxl])
        let bindingIndex = try XCTUnwrap(
            modeConfig.bindings.firstIndex {
                $0.id == "general-xxl-exact-loops-sub-luna"
            })
        modeConfig.bindings[bindingIndex].reasoningEffort = .low
        mutableBook.scenarios[scenarioIndex].modeConfigs[.xxl] = modeConfig

        let resolved = ChatTurnContractEffortResolver.resolve(
            route: try route("gpt-5.6-luna"),
            phase: .loops,
            contract: contract,
            uiSelectedEffort: .medium)

        XCTAssertEqual(
            mutableBook.scenarios[scenarioIndex].modeConfigs[.xxl]?
                .bindings[bindingIndex].reasoningEffort,
            .low)
        XCTAssertEqual(
            contract.loopGovernorDecision.activatedBindings.first {
                $0.id == "general-xxl-exact-loops-sub-luna"
            }?.reasoningEffort,
            .xhigh)
        XCTAssertEqual(resolved.requestedEffort, .xhigh)
    }

    func testNoMatchingBindingFallsBackToUIEffort() throws {
        let resolved = ChatTurnContractEffortResolver.resolve(
            route: try route("gpt-5.6-luna"),
            phase: .plan,
            contract: try exactContract(),
            uiSelectedEffort: .high)

        XCTAssertNil(resolved.contractBindingID)
        XCTAssertEqual(resolved.requestedEffort, .high)
        XCTAssertEqual(resolved.forwardedEffort, .high)
        XCTAssertTrue(resolved.canDispatch)
    }

    func testNativeGatewayRoutesUseUIEffortWhenThereIsNoContractBinding() throws {
        for routeID in [
            "fable5",
            "grok-build",
            "opus5",
            "sonnet5",
            "haiku4.5",
        ] {
            let resolved = ChatTurnContractEffortResolver.resolve(
                route: try route(routeID),
                phase: .loops,
                contract: nil,
                uiSelectedEffort: .xhigh)

            XCTAssertNil(resolved.contractBindingID, routeID)
            XCTAssertEqual(resolved.requestedEffort, .xhigh, routeID)
            XCTAssertEqual(resolved.forwardedEffort, .xhigh, routeID)
            XCTAssertEqual(
                resolved.effortOutcome,
                .forwardedAwaitingProvider,
                routeID)
            XCTAssertEqual(
                resolved.transcriptAttestationOutcome,
                .forwardedAwaitingProvider,
                routeID)
            XCTAssertTrue(resolved.canDispatch, routeID)
            XCTAssertNil(resolved.blocker, routeID)
        }
    }

    func testExactFableReviewerDispatchesWithoutNativeEffortClaim() throws {
        let fable = try route("fable5")
        XCTAssertFalse(fable.allowedEfforts.isEmpty)

        let resolved = ChatTurnContractEffortResolver.resolve(
            route: fable,
            phase: .loops,
            contract: try exactContract(),
            uiSelectedEffort: .xhigh)

        XCTAssertEqual(
            resolved.contractBindingID,
            "general-xxl-exact-loops-supervisor-fable5")
        XCTAssertNil(resolved.requestedEffort)
        XCTAssertNil(resolved.forwardedEffort)
        XCTAssertEqual(resolved.effortOutcome, .noNativeEffortRequested)
        XCTAssertEqual(
            resolved.transcriptAttestationOutcome,
            .providerEvidenceMissing)
        XCTAssertTrue(resolved.canDispatch)
    }

    func testNilAndNonNilEffortBindingsForSameRouteAndPhaseFailClosed() throws {
        let contract = try contractWithAmbiguousFableEffortBindings()

        let resolved = ChatTurnContractEffortResolver.resolve(
            route: try route("fable5"),
            phase: .loops,
            contract: contract,
            uiSelectedEffort: .xhigh)

        XCTAssertEqual(resolved.contractID, contract.contractID)
        XCTAssertNil(resolved.contractBindingID)
        XCTAssertNil(resolved.requestedEffort)
        XCTAssertNil(resolved.forwardedEffort)
        XCTAssertEqual(resolved.effortOutcome, .ambiguousContractBinding)
        XCTAssertEqual(
            resolved.transcriptAttestationOutcome,
            .providerMismatch)
        XCTAssertFalse(resolved.canDispatch)
        XCTAssertNotNil(resolved.blocker)
    }

    func testContractRequiredFableAndGrokEffortsAreForwardedWhenSupported() throws {
        let exact = try exactContract()
        let fableRequired = try contractRequiringEffort(
            bindingID: "general-xxl-exact-loops-supervisor-fable5",
            effort: .high)

        let cases: [(
            routeID: String,
            contract: TatwoWorkOSContractV1,
            expectedBinding: String,
            expectedEffort: TatwoCodexReasoningEffort
        )] = [
            (
                "fable5",
                fableRequired,
                "general-xxl-exact-loops-supervisor-fable5",
                TatwoCodexReasoningEffort.high
            ),
            (
                "grok-build",
                exact,
                "general-xxl-exact-loops-sub-grok",
                TatwoCodexReasoningEffort.xhigh
            ),
        ]
        for (routeID, contract, expectedBinding, expectedEffort) in cases {
            let resolved = ChatTurnContractEffortResolver.resolve(
                route: try route(routeID),
                phase: .loops,
                contract: contract,
                uiSelectedEffort: .low)

            XCTAssertEqual(resolved.contractBindingID, expectedBinding)
            XCTAssertEqual(resolved.requestedEffort, expectedEffort)
            XCTAssertEqual(resolved.forwardedEffort, expectedEffort)
            XCTAssertEqual(resolved.effortOutcome, .forwardedAwaitingProvider)
            XCTAssertEqual(
                resolved.transcriptAttestationOutcome,
                .forwardedAwaitingProvider)
            XCTAssertTrue(resolved.canDispatch)
            XCTAssertNil(resolved.blocker)
        }
    }

    func testQueuedTicketRetainsRouteContractAndEffortAfterUIPickerChanges() throws {
        let contract = try exactContract()
        let queuedSnapshot = ChatTurnContractEffortResolver.resolve(
            route: try route("gpt-5.6-sol"),
            phase: .plan,
            contract: contract,
            uiSelectedEffort: .xhigh)
        let ticket = ChatQueuedTicket(
            threadID: nil,
            discussionID: nil,
            messageID: "queued-message",
            displayTurn: "display",
            commandBaseTurn: "base",
            visibleTurn: "visible",
            attachmentPaths: [],
            preview: "preview",
            dispatchSnapshot: queuedSnapshot)

        let pickerAfterEnqueue = ChatTurnContractEffortResolver.resolve(
            route: try route("gpt-5.6-luna"),
            phase: .loops,
            contract: contract,
            uiSelectedEffort: .medium)

        XCTAssertEqual(ticket.dispatchSnapshot.routeID, "gpt-5.6-sol")
        XCTAssertEqual(ticket.dispatchSnapshot.canonicalModelID, "gpt-5.6-sol")
        XCTAssertEqual(
            ticket.dispatchSnapshot.contractBindingID,
            "general-xxl-exact-plan-lead-sol")
        XCTAssertEqual(ticket.dispatchSnapshot.requestedEffort, .low)
        XCTAssertEqual(ticket.dispatchSnapshot.forwardedEffort, .low)
        XCTAssertEqual(pickerAfterEnqueue.routeID, "gpt-5.6-luna")
        XCTAssertEqual(pickerAfterEnqueue.requestedEffort, .xhigh)
    }

    func testQueuedTurnUsesPendingRouteWhileCurrentTurnKeepsActiveRoute() throws {
        let active = try route("gpt-5.6-sol")
        let pending = try route("gpt-5.6-luna")

        XCTAssertEqual(
            ChatTurnDispatchRoutePolicy.route(
                active: active,
                pending: pending,
                isRunning: true
            ).id,
            "gpt-5.6-luna")
        XCTAssertEqual(
            ChatTurnDispatchRoutePolicy.route(
                active: active,
                pending: pending,
                isRunning: false
            ).id,
            "gpt-5.6-sol")
        XCTAssertEqual(
            ChatTurnDispatchRoutePolicy.route(
                active: active,
                pending: nil,
                isRunning: true
            ).id,
            "gpt-5.6-sol")
    }

    private func exactContract(
        book: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
    ) throws -> TatwoWorkOSContractV1 {
        try WorkOSFactory.projectContract(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
            objective: "exact XXL route contract focused test",
            scenarioBook: book)
    }

    private func contractRequiringEffort(
        bindingID: String,
        effort: TatwoCodexReasoningEffort
    ) throws -> TatwoWorkOSContractV1 {
        var book = TatwoScenarioConfigDefaults.book
        let scenarioIndex = try XCTUnwrap(
            book.scenarios.firstIndex {
                $0.id == TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID
            })
        var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
        let bindingIndex = try XCTUnwrap(
            config.bindings.firstIndex { $0.id == bindingID })
        config.bindings[bindingIndex].reasoningEffort = effort
        book.scenarios[scenarioIndex].modeConfigs[.xxl] = config
        return try exactContract(book: book)
    }

    private func contractWithAmbiguousFableEffortBindings()
        throws -> TatwoWorkOSContractV1
    {
        var book = TatwoScenarioConfigDefaults.book
        let scenarioIndex = try XCTUnwrap(
            book.scenarios.firstIndex {
                $0.id == TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID
            })
        var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
        let bindingIndex = try XCTUnwrap(
            config.bindings.firstIndex {
                $0.id == "general-xxl-exact-loops-supervisor-fable5"
            })
        var conflicting = config.bindings[bindingIndex]
        conflicting.id += "-conflicting-effort"
        conflicting.reasoningEffort = .high
        config.bindings.append(conflicting)
        book.scenarios[scenarioIndex].modeConfigs[.xxl] = config
        return try exactContract(book: book)
    }

    private func route(_ id: String) throws -> ChatRouteChoice {
        try XCTUnwrap(ChatRouteChoice.resolveOrNil(id))
    }
}
