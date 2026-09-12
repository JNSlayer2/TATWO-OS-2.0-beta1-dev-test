// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModels.swift；改動 4 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import Foundation

enum ChatComposerFooterState: String, Sendable, Equatable, CaseIterable {
    case neutral
    case recoveryRequired
    case waitingAuthorization
    case workContextUnbound
    case routeCooldown

    var presentationText: String {
        switch self {
        case .neutral: "無額外提醒"
        case .recoveryRequired: "需要復原"
        case .waitingAuthorization: "等待授權"
        case .workContextUnbound: "工作脈絡未綁定"
        case .routeCooldown: "路由冷卻"
        }
    }

    var isActive: Bool { self != .neutral }
}

struct ChatComposerFooterStateInputs: Sendable, Equatable {
    var isCLI = false
    var explicitWorkScope = false
    var recoveryRequired = false
    var waitingAuthorization = false
    var bindingRecoveryBlocked = false
    var routeDispatchAllowed = true
}

enum ChatComposerFooterStateResolver {
    static func resolve(
        _ inputs: ChatComposerFooterStateInputs
    ) -> ChatComposerFooterState {
        guard !inputs.isCLI, inputs.explicitWorkScope else {
            return .neutral
        }
        if inputs.recoveryRequired { return .recoveryRequired }
        if inputs.waitingAuthorization { return .waitingAuthorization }
        if inputs.bindingRecoveryBlocked { return .workContextUnbound }
        if !inputs.routeDispatchAllowed { return .routeCooldown }
        return .neutral
    }
}

enum ChatRouteBrandGroup: String, CaseIterable, Identifiable, Hashable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case xAI = "xAI"
    case miniMax = "MiniMax"
    case openClaw = "OpenClaw"
    case other = "Other"

    var id: String { rawValue }

    static let pickerOrder: [ChatRouteBrandGroup] = [
        .openAI,
        .anthropic,
        .xAI,
        .miniMax,
        .openClaw,
        .other,
    ]
}

struct ChatRouteBrandSection: Identifiable, Hashable {
    let brand: ChatRouteBrandGroup
    let choices: [ChatRouteChoice]

    var id: ChatRouteBrandGroup { brand }
}

struct ChatRouteChoice: Identifiable, Hashable {
    let profile: TatwoChatRouteProfile

    var id: String { profile.id }
    var title: String { profile.displayName }
    var family: String { profile.family }
    var engine: ChatEngine { profile.engine }
    var runtimeAdapter: TatwoChatRuntimeAdapter { profile.runtimeAdapter }
    var canonicalModelSlug: String { profile.canonicalModelSlug }
    var modelArgument: String? { profile.modelArgument }
    var defaultEffort: TatwoCodexReasoningEffort { profile.defaultEffort }
    var allowedEfforts: [TatwoCodexReasoningEffort] { profile.allowedEfforts }
    var defaultSpeedTier: TatwoModelSpeedTier? { profile.defaultSpeedTier }
    var allowedSpeedTiers: [TatwoModelSpeedTier] { profile.allowedSpeedTiers }
    var supportsNativeReasoningControl: Bool { profile.supportsNativeReasoningControl }
    var supportsNativeSpeedControl: Bool { profile.supportsNativeSpeedControl }

    var brandGroup: ChatRouteBrandGroup {
        let identities = [
            id,
            title,
            family,
            canonicalModelSlug,
            modelArgument ?? "",
        ].map { $0.lowercased() }

        if identities.contains(where: { $0.contains("openclaw") }) {
            return .openClaw
        }
        if identities.contains(where: { $0.contains("minimax") }) {
            return .miniMax
        }
        if identities.contains(where: { $0.contains("grok") }) {
            return .xAI
        }
        if engine == .claude || identities.contains(where: {
            $0.contains("anthropic")
                || $0.contains("claude")
                || $0.hasPrefix("fable")
                || $0.hasPrefix("haiku")
                || $0.hasPrefix("sonnet")
                || $0.hasPrefix("opus")
        }) {
            return .anthropic
        }
        if engine == .codex || identities.contains(where: {
            $0.hasPrefix("gpt-") || $0.hasPrefix("codex")
        }) {
            return .openAI
        }
        return .other
    }

    var commandLabel: String {
        // User-facing Chat UI should read as a Codex-App-like model selector, not
        // as a terminal command surface. The runtime adapter still owns the
        // actual launch plan; this label is only a compact model identity.
        profile.displayName
    }

    var providerIconID: String {
        let key = [id, family, canonicalModelSlug, modelArgument ?? ""]
            .joined(separator: " ")
            .lowercased()
        if key.contains("claude") || key.contains("sonnet") || key.contains("opus") || key.contains("fable") || engine == .claude {
            return "claude"
        }
        if key.contains("grok") { return "grok" }
        if key.contains("minimax") { return "minimax" }
        if key.contains("ollama") || key.contains("local") { return "local-api" }
        return "codex-gpt"
    }

    static let all: [ChatRouteChoice] = TatwoChatRouteProfile.defaults.map { ChatRouteChoice(profile: $0) }

    static func brandSections(selectedID: String?) -> [ChatRouteBrandSection] {
        var brands = ChatRouteBrandGroup.pickerOrder.filter { brand in
            all.contains { $0.brandGroup == brand }
        }
        if let selectedBrand = selectedID.flatMap(resolveOrNil)?.brandGroup,
           let selectedIndex = brands.firstIndex(of: selectedBrand),
           selectedIndex != brands.startIndex {
            brands.remove(at: selectedIndex)
            brands.insert(selectedBrand, at: brands.startIndex)
        }

        return brands.map { brand in
            ChatRouteBrandSection(
                brand: brand,
                choices: all.filter { $0.brandGroup == brand }
            )
        }
    }

    private static func normalizedLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func resolveOrNil(_ id: String) -> ChatRouteChoice? {
        let needle = normalizedLookupKey(id)
        guard !needle.isEmpty else { return nil }
        if let direct = all.first(where: { choice in
            [choice.id, choice.canonicalModelSlug, choice.modelArgument, choice.title, choice.family]
                .compactMap { $0 }
                .contains { normalizedLookupKey($0) == needle }
        }) {
            return direct
        }
        let compatible = TatwoChatRouteProfile.resolve(id)
        return all.first { $0.id == compatible.id }
    }

    static func resolve(_ id: String) -> ChatRouteChoice {
        resolveOrNil(id) ?? ChatRouteChoice(profile: TatwoChatRouteProfile.resolve(id))
    }
}

enum ChatTurnEffortResolutionOutcome: String, Codable, Equatable {
    /// The request was forwarded, but provider evidence has not attested that
    /// it became effective.
    case forwardedAwaitingProvider = "forwarded_awaiting_provider"
    /// This route has no proven native effort control and neither the issued
    /// contract nor the runtime requested one. The model may dispatch, but no
    /// effective effort claim is permitted.
    case noNativeEffortRequested = "no_native_effort_requested"
    case unsupportedRequestedEffort = "unsupported_requested_effort"
    case ambiguousContractBinding = "ambiguous_contract_binding"
    case unavailableRoute = "unavailable_route"
}

struct ChatComputerHostTurnDecision: Sendable, Equatable {
    let userRequested: Bool
    let route: TatwoComputerHostTurnRoute

    static let denied = Self(userRequested: false, route: .none)

    var isAuthorized: Bool {
        userRequested && route != .none
    }
}

struct ChatTurnDispatchSnapshot: Equatable {
    let routeID: String
    let canonicalModelID: String
    let vendorModelID: String?
    let phase: TatwoScenarioPhase
    let contractID: String?
    let contractBindingID: String?
    let requestedEffort: TatwoCodexReasoningEffort?
    let forwardedEffort: TatwoCodexReasoningEffort?
    let effortOutcome: ChatTurnEffortResolutionOutcome
    let blocker: String?
    /// Computer Host authority captured for this exact turn.
    ///
    /// This must travel with queued work instead of being inferred later from
    /// mutable model/UI state, otherwise a newer queued turn can rewrite the
    /// active run's tool authority.
    let computerHostDecision: ChatComputerHostTurnDecision

    init(
        routeID: String,
        canonicalModelID: String,
        vendorModelID: String?,
        phase: TatwoScenarioPhase,
        contractID: String?,
        contractBindingID: String?,
        requestedEffort: TatwoCodexReasoningEffort?,
        forwardedEffort: TatwoCodexReasoningEffort?,
        effortOutcome: ChatTurnEffortResolutionOutcome,
        blocker: String?,
        computerHostDecision: ChatComputerHostTurnDecision = .denied
    ) {
        self.routeID = routeID
        self.canonicalModelID = canonicalModelID
        self.vendorModelID = vendorModelID
        self.phase = phase
        self.contractID = contractID
        self.contractBindingID = contractBindingID
        self.requestedEffort = requestedEffort
        self.forwardedEffort = forwardedEffort
        self.effortOutcome = effortOutcome
        self.blocker = blocker
        self.computerHostDecision = computerHostDecision
    }

    var canDispatch: Bool {
        switch effortOutcome {
        case .forwardedAwaitingProvider:
            return forwardedEffort != nil
        case .noNativeEffortRequested:
            return requestedEffort == nil && forwardedEffort == nil
        case .unsupportedRequestedEffort, .ambiguousContractBinding,
             .unavailableRoute:
            return false
        }
    }

    var transcriptAttestationOutcome: ChatTranscriptAttestationOutcomeV1 {
        switch effortOutcome {
        case .forwardedAwaitingProvider:
            return .forwardedAwaitingProvider
        case .noNativeEffortRequested:
            return .providerEvidenceMissing
        case .unsupportedRequestedEffort:
            return .unsupportedEffort
        case .ambiguousContractBinding, .unavailableRoute:
            return .providerMismatch
        }
    }
}

enum ChatConfirmedPlanDispatchBindingPolicy {
    static func matches(
        snapshotContractID: String?,
        snapshotBindingID: String?,
        dispatchContractID: String,
        dispatchBindingID: String,
        dispatchSourceSlotID: String,
        issuedBindingID: String,
        issuedSourceSlotID: String
    ) -> Bool {
        snapshotContractID == dispatchContractID
            && snapshotBindingID == dispatchSourceSlotID
            && issuedBindingID == dispatchBindingID
            && issuedSourceSlotID == dispatchSourceSlotID
    }
}

struct ChatComputerHostTurnBinding: Sendable, Equatable {
    let runID: String
    let sessionID: String
    let decision: ChatComputerHostTurnDecision
    let contractID: String?
    let mainlineLoopID: String?
    let workspaceRoot: String?
    let lease: TatwoHostApprovalLeaseV1?
    let appMCPEndpoint: TatwoAppMCPEndpoint?
}

struct ChatComputerHostTurnBindingSlot: Sendable, Equatable {
    private var bindingsByRunID: [String: ChatComputerHostTurnBinding] = [:]

    mutating func install(_ binding: ChatComputerHostTurnBinding) -> Bool {
        guard !binding.runID.isEmpty else { return false }
        guard bindingsByRunID[binding.runID] == nil else { return false }
        bindingsByRunID[binding.runID] = binding
        return true
    }

    func binding(for runID: String) -> ChatComputerHostTurnBinding? {
        guard !runID.isEmpty else { return nil }
        return bindingsByRunID[runID]
    }

    mutating func take(runID: String) -> ChatComputerHostTurnBinding? {
        guard !runID.isEmpty else { return nil }
        return bindingsByRunID.removeValue(forKey: runID)
    }
}

struct ChatComputerLeaseRenewalContext: Sendable, Equatable {
    let requestedRunID: String
    let activeRunID: String?
    let requestedContractID: String
    let activeContractID: String?
    let contractIsValid: Bool
    let turnIsRunning: Bool
    let userInterrupted: Bool

    var mayRenew: Bool {
        !requestedRunID.isEmpty
            && requestedRunID == activeRunID
            && !requestedContractID.isEmpty
            && requestedContractID == activeContractID
            && contractIsValid
            && turnIsRunning
            && !userInterrupted
    }
}

struct ChatComputerAutoContinuationBudget: Sendable, Equatable {
    private(set) var completedSteps = 0
    let maximumSteps: Int

    init(maximumSteps: Int = 15) {
        self.maximumSteps = max(1, maximumSteps)
    }

    mutating func consumeStep() -> Bool {
        guard completedSteps < maximumSteps else { return false }
        completedSteps += 1
        return true
    }

    var isExhausted: Bool {
        completedSteps >= maximumSteps
    }
}

struct PlanQuestionAnswerV1: Sendable, Equatable {
    let questionID: String
    let selectedOptions: [PlanQuestionV1.Option]
    let otherText: String?
    let skipped: Bool

    init(
        questionID: String,
        selectedOptions: [PlanQuestionV1.Option] = [],
        otherText: String? = nil,
        skipped: Bool = false
    ) {
        self.questionID = questionID
        self.selectedOptions = selectedOptions
        self.otherText = otherText
        self.skipped = skipped
    }
}

struct PlanQuestionResponseBatchV1: Sendable, Equatable {
    let answers: [PlanQuestionAnswerV1]
}

enum PlanClarificationVerticalDirection: Sendable, Equatable {
    case up
    case down
}

enum PlanClarificationVerticalMove: Sendable, Equatable {
    case stay
    case selectOption(index: Int)
    case focusOther
}

enum PlanClarificationSkipIntent: Sendable, Equatable {
    case skip
    case submitAnswer
}

enum PlanClarificationReturnIntent: Sendable, Equatable {
    case reselectOption(index: Int)
    case advance
}

enum PlanClarificationSelectionSource: Sendable, Equatable {
    case explicitCommit
    case verticalNavigation
}

enum PlanClarificationSelectionIntent: Sendable, Equatable {
    case ignore
    case selectOnly
    case selectAndAutoAdvance
}

enum PlanClarificationNumericShortcutIntent: Sendable, Equatable {
    case ignore
    case selectOption(index: Int)
    case focusOther
}

enum PlanClarificationOtherArrowIntent: Sendable, Equatable {
    case focusPreviousOption
    case preserveEditorNavigation
}

enum PlanClarificationOtherEditorPolicy {
    static func arrowUpIntent(
        renderedHeight: CGFloat,
        singleLineHeight: CGFloat
    ) -> PlanClarificationOtherArrowIntent {
        guard singleLineHeight > 0,
              renderedHeight > singleLineHeight * 1.1
        else {
            return .focusPreviousOption
        }
        return .preserveEditorNavigation
    }
}

enum PlanClarificationCodexPresentation {
    static let defaultOtherPlaceholder =
        "No, and tell ChatGPT what to do differently"
    static let optionPointSize: CGFloat = 13
    static let descriptionPointSize: CGFloat = 13
    static let actionPointSize: CGFloat = 13
    static let counterPointSize: CGFloat = 12
    static let composerMarkerSize: CGFloat = 18
    static let otherEditorMinimumHeight: CGFloat = 20
    static let otherEditorMaximumHeight: CGFloat = 128
}

enum PlanClarificationInteractionPolicy {
    static func shouldClaimInitialFocus(
        isLatestAssistantMessage: Bool,
        alreadyClaimed: Bool
    ) -> Bool {
        isLatestAssistantMessage && !alreadyClaimed
    }

    static func otherMarkerIsActive(
        isFocused: Bool,
        selectedOptionCount: Int,
        otherText: String
    ) -> Bool {
        isFocused || (selectedOptionCount == 0 && !otherText.isEmpty)
    }

    static func numericShortcut(
        number: Int,
        optionCount: Int,
        allowsOtherResponse: Bool = true,
        autoAdvancePending: Bool = false
    ) -> PlanClarificationNumericShortcutIntent {
        guard !autoAdvancePending else { return .ignore }
        guard (1...9).contains(number), optionCount >= 0 else {
            return .ignore
        }
        let optionIndex = number - 1
        if optionIndex < optionCount {
            return .selectOption(index: optionIndex)
        }
        return allowsOtherResponse && optionIndex == optionCount
            ? .focusOther
            : .ignore
    }

    static func allowsKeyboardQuestionNavigation(
        autoAdvancePending: Bool
    ) -> Bool {
        !autoAdvancePending
    }

    static func allowsCardShortcuts(
        isOtherEditorFocused: Bool
    ) -> Bool {
        !isOtherEditorFocused
    }

    static func updatedMultiSelectOrder(
        selectedOptionLabels: [String],
        toggledOptionLabel: String
    ) -> [String] {
        if selectedOptionLabels.contains(toggledOptionLabel) {
            return selectedOptionLabels.filter { $0 != toggledOptionLabel }
        }
        return selectedOptionLabels + [toggledOptionLabel]
    }

    static func selectionOrderAfterNumericOther(
        allowsMultipleSelections: Bool,
        selectedOptionLabels: [String]
    ) -> [String] {
        allowsMultipleSelections ? [] : selectedOptionLabels
    }

    static func initialFocusedOptionIndex(
        allowsMultipleSelections: Bool,
        optionCount: Int
    ) -> Int {
        guard optionCount > 0 else { return -1 }
        return allowsMultipleSelections ? -1 : 0
    }

    static func verticalMove(
        from focusedIndex: Int,
        direction: PlanClarificationVerticalDirection,
        optionCount: Int,
        allowsOtherResponse: Bool = true
    ) -> PlanClarificationVerticalMove {
        guard optionCount > 0 else {
            return direction == .down && allowsOtherResponse
                ? .focusOther
                : .stay
        }

        switch direction {
        case .up:
            if focusedIndex < 0 {
                return .selectOption(index: optionCount - 1)
            }
            guard focusedIndex > 0 else { return .stay }
            return .selectOption(
                index: min(focusedIndex - 1, optionCount - 1))
        case .down:
            guard focusedIndex < optionCount else { return .stay }
            let destination = focusedIndex + 1
            return destination == optionCount
                ? (allowsOtherResponse ? .focusOther : .stay)
                : .selectOption(index: destination)
        }
    }

    static func skipIntent(
        allowsMultipleSelections: Bool,
        selectedOptionCount: Int,
        otherText: String
    ) -> PlanClarificationSkipIntent {
        let hasOtherResponse = !otherText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasMultiSelectResponse =
            allowsMultipleSelections && selectedOptionCount > 0
        return hasOtherResponse || hasMultiSelectResponse
            ? .submitAnswer
            : .skip
    }

    static func returnIntent(
        allowsMultipleSelections: Bool,
        selectedOptionIndex: Int?
    ) -> PlanClarificationReturnIntent {
        guard !allowsMultipleSelections, let selectedOptionIndex else {
            return .advance
        }
        return .reselectOption(index: selectedOptionIndex)
    }

    static func selectionIntent(
        allowsMultipleSelections: Bool,
        source: PlanClarificationSelectionSource,
        autoAdvancePending: Bool
    ) -> PlanClarificationSelectionIntent {
        guard !autoAdvancePending else { return .ignore }
        guard !allowsMultipleSelections else { return .selectOnly }
        return source == .verticalNavigation
            ? .selectOnly
            : .selectAndAutoAdvance
    }
}

struct PlanFlowSelectionProjectionV1: Sendable, Equatable {
    let selection: TatwoPlanArtifactV1.PlanFlowSelectionV1
    let missingSelections: [String]

    var isComplete: Bool { missingSelections.isEmpty }
}

enum ChatTurnDispatchRoutePolicy {
    static func route(
        active: ChatRouteChoice,
        pending: ChatRouteChoice?,
        isRunning: Bool
    ) -> ChatRouteChoice {
        guard isRunning, let pending else { return active }
        return pending
    }
}

/// Resolves one immutable turn from the already-issued Work OS contract.
///
/// This resolver intentionally has no Scenario Config Book parameter. Runtime
/// turns must not re-read mutable staging configuration after a contract was
/// issued. The UI effort is consulted only when no matching contract binding
/// explicitly requires an effort for the canonical route and current phase.
enum ChatTurnContractEffortResolver {
    static func resolve(
        route: ChatRouteChoice,
        phase: TatwoScenarioPhase,
        contract: TatwoWorkOSContractV1?,
        uiSelectedEffort: TatwoCodexReasoningEffort,
        computerHostDecision: ChatComputerHostTurnDecision = .denied
    ) -> ChatTurnDispatchSnapshot {
        let canonicalRoute = canonicalModelID(route.canonicalModelSlug)
        guard route.runtimeAdapter != .unavailable else {
            return ChatTurnDispatchSnapshot(
                routeID: route.id,
                canonicalModelID: canonicalRoute,
                vendorModelID: route.modelArgument,
                phase: phase,
                contractID: contract?.contractID,
                contractBindingID: nil,
                requestedEffort: nil,
                forwardedEffort: nil,
                effortOutcome: .unavailableRoute,
                blocker: "route \(canonicalRoute) unavailable；沒有派工。",
                computerHostDecision: computerHostDecision)
        }

        let matches = contract?.loopGovernorDecision.activatedBindings.filter { binding in
            binding.enabled
                && binding.dynamicActivation != .disabled
                && binding.phase == phase
                && binding.boundModelIDs.contains {
                    canonicalModelID($0) == canonicalRoute
                }
        } ?? []
        // Optionality is contract-significant: nil means explicitly do not
        // request/forward native effort. compactMap would erase that decision
        // and incorrectly treat [nil, .high] as one unambiguous .high binding.
        let bindingEffortVariants = Set(matches.map(\.reasoningEffort))
        if bindingEffortVariants.count > 1 {
            return ChatTurnDispatchSnapshot(
                routeID: route.id,
                canonicalModelID: canonicalRoute,
                vendorModelID: route.modelArgument,
                phase: phase,
                contractID: contract?.contractID,
                contractBindingID: nil,
                requestedEffort: nil,
                forwardedEffort: nil,
                effortOutcome: .ambiguousContractBinding,
                blocker:
                    "contract \(contract?.contractID ?? "unknown") 對 \(canonicalRoute)/\(phase.rawValue) 有互相衝突的 effort bindings；沒有派工。",
                computerHostDecision: computerHostDecision)
        }

        if let matchedBinding = matches.first(where: {
            $0.reasoningEffort != nil
        }), let requested = matchedBinding.reasoningEffort {
            guard route.allowedEfforts.contains(requested) else {
                return ChatTurnDispatchSnapshot(
                    routeID: route.id,
                    canonicalModelID: canonicalRoute,
                    vendorModelID: route.modelArgument,
                    phase: phase,
                    contractID: contract?.contractID,
                    contractBindingID: matchedBinding.id,
                    requestedEffort: requested,
                    forwardedEffort: nil,
                    effortOutcome: .unsupportedRequestedEffort,
                    blocker:
                        "route \(canonicalRoute) 沒有 \(requested.rawValue) effort 的 provider capability 證據；contract-required effort 未轉送，沒有派工。",
                    computerHostDecision: computerHostDecision)
            }
            return ChatTurnDispatchSnapshot(
                routeID: route.id,
                canonicalModelID: canonicalRoute,
                vendorModelID: route.modelArgument,
                phase: phase,
                contractID: contract?.contractID,
                contractBindingID: matchedBinding.id,
                requestedEffort: requested,
                forwardedEffort: requested,
                effortOutcome: .forwardedAwaitingProvider,
                blocker: nil,
                computerHostDecision: computerHostDecision)
        }

        let matchedBinding = matches.first
        if let matchedBinding {
            // A matching issued binding with nil effort is an explicit contract
            // decision, not permission to inherit the mutable UI picker. The
            // exact XXL profile uses this for the Fable reviewer so the runtime
            // must keep the turn effort-less even after the route gains native
            // effort forwarding capability.
            return ChatTurnDispatchSnapshot(
                routeID: route.id,
                canonicalModelID: canonicalRoute,
                vendorModelID: route.modelArgument,
                phase: phase,
                contractID: contract?.contractID,
                contractBindingID: matchedBinding.id,
                requestedEffort: nil,
                forwardedEffort: nil,
                effortOutcome: .noNativeEffortRequested,
                blocker: nil,
                computerHostDecision: computerHostDecision)
        }
        guard !route.allowedEfforts.isEmpty else {
            return ChatTurnDispatchSnapshot(
                routeID: route.id,
                canonicalModelID: canonicalRoute,
                vendorModelID: route.modelArgument,
                phase: phase,
                contractID: contract?.contractID,
                contractBindingID: nil,
                requestedEffort: nil,
                forwardedEffort: nil,
                effortOutcome: .noNativeEffortRequested,
                blocker: nil,
                computerHostDecision: computerHostDecision)
        }
        let requested = route.allowedEfforts.contains(uiSelectedEffort)
            ? uiSelectedEffort
            : (
                route.allowedEfforts.contains(route.defaultEffort)
                    ? route.defaultEffort
                    : route.allowedEfforts[0]
            )
        return ChatTurnDispatchSnapshot(
            routeID: route.id,
            canonicalModelID: canonicalRoute,
            vendorModelID: route.modelArgument,
            phase: phase,
            contractID: contract?.contractID,
            contractBindingID: nil,
            requestedEffort: requested,
            forwardedEffort: requested,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil,
            computerHostDecision: computerHostDecision)
    }

    private static func canonicalModelID(_ raw: String) -> String {
        TatwoModelIdentityRegistry.canonicalModelID(for: raw)
            ?? ChatRouteChoice.resolveOrNil(raw)?.canonicalModelSlug
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ChatCLISessionSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let updatedAt: Date
    let rawPreview: String
    let isRunning: Bool
}

enum ChatAttachmentTranscript {
    struct Attachment: Equatable {
        let path: String
        let name: String
    }

    static func displayTurn(
        text: String,
        attachmentPaths: [String],
        attachmentDisplayNames: [String: String] = [:],
        imageStore: TatwoImageAssetStore = TatwoImageAssetStore()
    ) -> String {
        var seen = Set<String>()
        let markers = attachmentPaths.compactMap { rawPath -> String? in
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            let url = URL(fileURLWithPath: path)
            let storedName = attachmentDisplayNames[path]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = storedName?.isEmpty == false
                ? storedName!
                : (url.lastPathComponent.isEmpty ? "附件" : url.lastPathComponent)
            if markerKind(for: url) == "image",
               let asset = imageStore.relativePath(for: url) {
                return "<image name=[\(escapedAttribute(name))] asset=\"\(escapedAttribute(asset))\">"
            }
            return "<\(markerKind(for: url)) name=[\(escapedAttribute(name))] path=\"\(escapedAttribute(path))\">"
        }
        guard !markers.isEmpty else { return text }
        let separator = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        return text + separator + markers.joined(separator: "\n")
    }

    static func previewText(
        userText: String,
        attachmentPaths: [String],
        attachmentDisplayNames: [String: String] = [:]
    ) -> String {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        let filenames = attachmentPaths.compactMap { rawPath -> String? in
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }
            let name = attachmentDisplayNames[path]
                ?? URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? nil : name
        }
        guard let first = filenames.first else { return "新訊息" }
        if filenames.count == 1 {
            let kind = markerKind(for: URL(fileURLWithPath: first)) == "image" ? "圖片附件" : "附件"
            return "\(kind) · \(first)"
        }
        return "\(filenames.count) 個附件"
    }

    static func attachments(
        in text: String,
        imageStore: TatwoImageAssetStore = TatwoImageAssetStore()
    ) -> [Attachment] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(?:image|video|file)\b[^>]*>"#)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let tag = String(text[matchRange])
            let path: String
            if let rawAsset = capture(#"asset="([^"]+)""#, in: tag),
               let url = imageStore.resolve(relativePath: decodedAttribute(rawAsset)) {
                path = url.path
            } else if let rawPath = capture(#"path="([^"]+)""#, in: tag) {
                path = decodedAttribute(rawPath)
            } else {
                return nil
            }
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            let rawName = capture(#"name=\[?([^\]">]+)\]?"#, in: tag)
            let fallback = URL(fileURLWithPath: path).lastPathComponent
            return Attachment(
                path: path,
                name: rawName.map(decodedAttribute) ?? (fallback.isEmpty ? "附件" : fallback))
        }
    }

    static func migratingLegacyImageMarkers(
        in text: String,
        imageStore: TatwoImageAssetStore = TatwoImageAssetStore()
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<image\b[^>]*\bpath="[^"]+"[^>]*>"#)
        else { return text }
        var output = text
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range).reversed() {
            guard let sourceRange = Range(match.range, in: text),
                  let outputRange = Range(match.range, in: output)
            else { continue }
            let tag = String(text[sourceRange])
            guard let rawPath = capture(#"path="([^"]+)""#, in: tag) else { continue }
            let path = decodedAttribute(rawPath)
            guard TatwoImageAssetStore.isImageCandidatePath(path),
                  TatwoImageAssetStore.isDecodableImageFile(atPath: path)
            else { continue }
            let rawName = capture(#"name=\[?([^\]">]+)\]?"#, in: tag)
            let fallback = URL(fileURLWithPath: path).lastPathComponent
            let name = rawName.map(decodedAttribute)
                ?? (fallback.isEmpty ? "圖片附件" : fallback)
            guard let asset = try? imageStore.ingest(
                fileURL: URL(fileURLWithPath: path),
                displayName: name)
            else { continue }
            let replacement =
                "<image name=[\(escapedAttribute(name))] asset=\"\(escapedAttribute(asset.relativePath))\">"
            output.replaceSubrange(outputRange, with: replacement)
        }
        return output
    }

    private static func markerKind(for url: URL) -> String {
        if TatwoImageAssetStore.isImageCandidatePath(url.path) {
            return "image"
        }
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "webm"].contains(ext) {
            return "video"
        }
        return "file"
    }

    private static func escapedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "]", with: "&#93;")
    }

    private static func decodedAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&#93;", with: "]")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }
}

struct ChatImageDispatchSelection: Equatable {
    let paths: [String]
    let missingNames: [String]
    let omittedCount: Int
}

enum ChatImageDispatchSelector {
    static func select(
        currentPaths: [String],
        transcriptTexts: [String],
        imageStore: TatwoImageAssetStore = TatwoImageAssetStore(),
        limit: Int = 8,
        totalByteLimit: Int = 32 * 1024 * 1024
    ) -> ChatImageDispatchSelection {
        let safeLimit = max(0, limit)
        var seen = Set<String>()
        var existing: [String] = []
        var missingNames: [String] = []

        func append(path: String, name: String) {
            guard TatwoImageAssetStore.isImageCandidatePath(path),
                  seen.insert(path).inserted
            else { return }
            if TatwoImageAssetStore.isDecodableImageFile(atPath: path) {
                existing.append(path)
            } else {
                missingNames.append(name)
            }
        }

        for path in currentPaths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            append(path: path, name: name.isEmpty ? "圖片附件" : name)
        }
        for text in transcriptTexts.reversed() {
            for attachment in ChatAttachmentTranscript.attachments(
                in: text,
                imageStore: imageStore
            ).reversed() {
                append(path: attachment.path, name: attachment.name)
            }
        }

        var selected: [String] = []
        var selectedBytes = 0
        for path in existing {
            guard selected.count < safeLimit else { continue }
            let byteCount = ((try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard byteCount > 0,
                  selectedBytes + byteCount <= max(0, totalByteLimit)
            else { continue }
            selected.append(path)
            selectedBytes += byteCount
        }

        return ChatImageDispatchSelection(
            paths: selected,
            missingNames: missingNames,
            omittedCount: max(0, existing.count - selected.count))
    }
}

enum ChatHistoricalImageBridgePolicy {
    static func shouldBridge(
        visibleTurn: String,
        interactionMode: TatwoChatInteractionMode,
        targetRuntimeAdapter: TatwoChatRuntimeAdapter,
        targetHasResumableSession _: Bool
    ) -> Bool {
        guard interactionMode == .standard else { return false }
        guard targetRuntimeAdapter != .unavailable else { return false }
        let normalized = visibleTurn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let priorReferences = [
            "上一張", "前一張", "上張", "先前的圖", "之前的圖",
            "剛才的圖", "剛剛的圖", "貼上的圖片", "附過的圖片",
            "previous image", "previous photo", "previous screenshot",
            "last image", "last photo", "last screenshot"
        ]
        if priorReferences.contains(where: { normalized.contains($0) }) {
            return true
        }

        let historicalReferences = [
            "上一則", "前一則", "第一則", "先前", "之前", "剛才", "剛剛",
            "本 thread", "這個 thread", "本討論串", "這個討論串",
            "previous", "last", "earlier", "first message", "this thread"
        ]
        let imageReferences = [
            "附件圖片", "附件中的圖", "圖片", "照片", "截圖",
            "image", "photo", "screenshot"
        ]
        return historicalReferences.contains(where: { normalized.contains($0) })
            && imageReferences.contains(where: { normalized.contains($0) })
    }
}

struct ChatSidebarThreadRef: Identifiable, Equatable {
    let project: TatwoNativeChatProject?
    let thread: TatwoNativeChatThread

    var id: UUID { thread.id }
}

struct ChatSidebarThreadTreeRow: Identifiable {
    let thread: TatwoNativeChatThread
    let depth: Int
    var id: UUID { thread.id }

    /// Flatten once in sibling order, without recursive SwiftUI views or
    /// another state store. Orphans and malformed cycles remain reachable.
    static func rows(_ threads: [TatwoNativeChatThread]) -> [Self] {
        let ids = Set(threads.map(\.id))
        var children: [UUID: [TatwoNativeChatThread]] = [:]
        var roots: [TatwoNativeChatThread] = []
        for thread in threads {
            if let parent = thread.parentThreadID, parent != thread.id, ids.contains(parent) {
                children[parent, default: []].append(thread)
            } else {
                roots.append(thread)
            }
        }
        var visited = Set<UUID>()
        var result: [Self] = []
        for root in roots + threads {
            guard !visited.contains(root.id) else { continue }
            var stack: [Self] = [.init(thread: root, depth: 0)]
            while let row = stack.popLast() {
                guard visited.insert(row.id).inserted else { continue }
                result.append(row)
                for child in (children[row.id] ?? []).reversed() {
                    stack.append(.init(thread: child, depth: row.depth + 1))
                }
            }
        }
        return result
    }
}

struct ThreadSubagentPresentationRow: Identifiable {
    let id: String
    let identityLabel: String
    let modelID: String
    let statusLabel: String
    let detail: String
    let route: ChatRouteChoice
    let tint: Color
}

enum ChatMessageRole {
    case user
    case assistant
    case system

    var storageValue: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .system: "system"
        }
    }

    static func storageValue(_ raw: String) -> ChatMessageRole {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user", "you":
            return .user
        case "assistant", "cli", "codex", "claude":
            return .assistant
        case "system", "os", "work-os":
            return .system
        default:
            return .system
        }
    }

    var label: String {
        switch self {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "OS"
        }
    }

    var color: Color {
        switch self {
        case .user: .accentColor
        case .assistant: .purple
        case .system: .orange
        }
    }

    var terminalPrefix: String {
        switch self {
        case .user: "$ user"
        case .assistant: "  ai"
        case .system: "# os"
        }
    }
}

extension ChatMessageRole {
    var transcriptPresentationRole: TatwoChatTranscriptRole {
        switch self {
        case .user: .user
        case .assistant: .assistant
        case .system: .system
        }
    }
}

/// Small, deterministic content identity computed only when source content
/// changes. Hot SwiftUI getters use this O(1) value instead of rescanning a
/// full streaming message merely to ask the derived-value cache for a hit.
struct ChatStableContentFingerprint: Hashable {
    let utf8Count: Int
    let primary: UInt64
    let secondary: UInt64

    static let empty = ChatStableContentFingerprint("")

    init(_ text: String) {
        utf8Count = text.utf8.count
        var primary: UInt64 = 14_695_981_039_346_656_037
        var secondary: UInt64 = 10_995_116_282_11
        for byte in text.utf8 {
            primary ^= UInt64(byte)
            primary &*= 1_099_511_628_211

            secondary &+= UInt64(byte) &+ 0x9e37_79b9
            secondary ^= secondary >> 29
            secondary &*= 0x1656_67b1_9e37_79f9
        }
        self.primary = primary
        self.secondary = secondary
    }

    private init(
        utf8Count: Int,
        primary: UInt64,
        secondary: UInt64
    ) {
        self.utf8Count = utf8Count
        self.primary = primary
        self.secondary = secondary
    }

    /// Extends the same deterministic fingerprint by scanning only the newly
    /// arrived UTF-8 suffix. The streaming hot path can therefore update its
    /// semantic key without rescanning the entire accumulated assistant reply.
    func appending(_ suffix: String) -> Self {
        guard !suffix.isEmpty else { return self }
        var updatedPrimary = primary
        var updatedSecondary = secondary
        var appendedUTF8Count = 0
        for byte in suffix.utf8 {
            appendedUTF8Count += 1
            updatedPrimary ^= UInt64(byte)
            updatedPrimary &*= 1_099_511_628_211

            updatedSecondary &+= UInt64(byte) &+ 0x9e37_79b9
            updatedSecondary ^= updatedSecondary >> 29
            updatedSecondary &*= 0x1656_67b1_9e37_79f9
        }
        return Self(
            utf8Count: utf8Count + appendedUTF8Count,
            primary: updatedPrimary,
            secondary: updatedSecondary)
    }
}

private struct ChatDeterministicSemanticAccumulator {
    private(set) var primary: UInt64 = 0xcbf2_9ce4_8422_2325
    private(set) var secondary: UInt64 = 0x9e37_79b9_7f4a_7c15
    private(set) var componentCount = 0

    mutating func append(_ value: UInt64) {
        componentCount += 1
        primary ^= value &+ 0x9e37_79b9_7f4a_7c15
        primary &*= 0x0000_0100_0000_01b3
        primary ^= primary >> 31

        secondary ^= value &+ UInt64(componentCount)
        secondary = (secondary << 27) | (secondary >> 37)
        secondary &*= 0x1656_67b1_9e37_79f9
    }

    mutating func append(_ value: Int) {
        append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Bool) {
        append(value ? 1 : 0)
    }

    mutating func append(_ fingerprint: ChatStableContentFingerprint) {
        append(fingerprint.utf8Count)
        append(fingerprint.primary)
        append(fingerprint.secondary)
    }
}

/// Fixed-size, deterministic identity for every semantic field consumed by the
/// transcript display. It deliberately stores no source String or question
/// array. Equality is collision-resistant rather than mathematically
/// collision-proof; exact-source caches still keep their own equality guards.
struct ChatMessageSemanticIdentity: Equatable {
    let semanticByteCount: Int
    let primary: UInt64
    let secondary: UInt64

    fileprivate init(
        idFingerprint: ChatStableContentFingerprint,
        role: ChatMessageRole,
        textFingerprint: ChatStableContentFingerprint,
        statusFingerprint: ChatStableContentFingerprint,
        statusWasNil: Bool,
        modelIDFingerprint: ChatStableContentFingerprint,
        modelIDWasNil: Bool,
        eventKindFingerprint: ChatStableContentFingerprint,
        runtimeAdapterFingerprint: ChatStableContentFingerprint,
        runtimeAdapterWasNil: Bool,
        runtimeFallbackFingerprint: ChatStableContentFingerprint,
        runtimeFallbackWasNil: Bool,
        turnFingerprint: ChatStableContentFingerprint,
        turnWasNil: Bool,
        planQuestionsFingerprint: ChatStableContentFingerprint,
        createdAt: Date
    ) {
        var accumulator = ChatDeterministicSemanticAccumulator()
        accumulator.append(1)
        accumulator.append(idFingerprint)
        switch role {
        case .user:
            accumulator.append(1)
        case .assistant:
            accumulator.append(2)
        case .system:
            accumulator.append(3)
        }
        accumulator.append(textFingerprint)
        accumulator.append(statusWasNil)
        accumulator.append(statusFingerprint)
        accumulator.append(modelIDWasNil)
        accumulator.append(modelIDFingerprint)
        accumulator.append(eventKindFingerprint)
        accumulator.append(runtimeAdapterWasNil)
        accumulator.append(runtimeAdapterFingerprint)
        accumulator.append(runtimeFallbackWasNil)
        accumulator.append(runtimeFallbackFingerprint)
        accumulator.append(turnWasNil)
        accumulator.append(turnFingerprint)
        accumulator.append(planQuestionsFingerprint)
        accumulator.append(createdAt.timeIntervalSinceReferenceDate.bitPattern)

        semanticByteCount =
            idFingerprint.utf8Count
            + textFingerprint.utf8Count
            + statusFingerprint.utf8Count
            + modelIDFingerprint.utf8Count
            + eventKindFingerprint.utf8Count
            + runtimeAdapterFingerprint.utf8Count
            + runtimeFallbackFingerprint.utf8Count
            + turnFingerprint.utf8Count
            + planQuestionsFingerprint.utf8Count
        primary = accumulator.primary
        secondary = accumulator.secondary
    }

    fileprivate static func planQuestionsFingerprint(
        _ questions: [PlanQuestionV1]
    ) -> ChatStableContentFingerprint {
        var fingerprint = ChatStableContentFingerprint.empty

        func appendingFramed(
            _ value: String,
            to current: ChatStableContentFingerprint
        ) -> ChatStableContentFingerprint {
            current
                .appending(String(value.utf8.count))
                .appending(":")
                .appending(value)
                .appending(";")
        }

        fingerprint = fingerprint
            .appending("questions:")
            .appending(String(questions.count))
            .appending(";")
        for question in questions {
            fingerprint = appendingFramed(question.id, to: fingerprint)
            fingerprint = appendingFramed(question.question, to: fingerprint)
            fingerprint = fingerprint
                .appending(question.allowsMultipleSelections ? "1" : "0")
                .appending(question.allowsOtherResponse ? "1" : "0")
                .appending(String(question.options.count))
                .appending(";")
            for option in question.options {
                fingerprint = appendingFramed(option.label, to: fingerprint)
                fingerprint = appendingFramed(option.detail, to: fingerprint)
            }
        }
        return fingerprint
    }
}

struct ChatTranscriptSemanticRevision: Equatable {
    static let empty = ChatTranscriptSemanticRevision(
        messageCount: 0,
        primary: 0xcbf2_9ce4_8422_2325,
        secondary: 0x9e37_79b9_7f4a_7c15)

    let messageCount: Int
    let primary: UInt64
    let secondary: UInt64

    init(_ messages: [ChatMessage]) {
        var revision = Self.empty
        for message in messages {
            revision = revision.appending(message.displaySemanticIdentity)
        }
        self = revision
    }

    func appending(
        _ identity: ChatMessageSemanticIdentity
    ) -> ChatTranscriptSemanticRevision {
        var accumulator = ChatDeterministicSemanticAccumulator()
        accumulator.append(primary)
        accumulator.append(secondary)
        accumulator.append(messageCount &+ 1)
        accumulator.append(identity.semanticByteCount)
        accumulator.append(identity.primary)
        accumulator.append(identity.secondary)
        return ChatTranscriptSemanticRevision(
            messageCount: messageCount &+ 1,
            primary: accumulator.primary,
            secondary: accumulator.secondary)
    }

    private init(
        messageCount: Int,
        primary: UInt64,
        secondary: UInt64
    ) {
        self.messageCount = messageCount
        self.primary = primary
        self.secondary = secondary
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: ChatMessageRole
    var text: String {
        didSet {
            guard !isApplyingIncrementalTextAppend else { return }
            guard text != oldValue else { return }
            derivedTextRevision = UUID()
            derivedTextAppendBaseRevision = nil
            derivedTextAppendSuffix = nil
            derivedTextFingerprint = ChatStableContentFingerprint(text)
            derivedTextUTF8Count = derivedTextFingerprint.utf8Count
            refreshDisplaySemanticIdentity()
        }
    }
    var status: String? {
        didSet {
            guard status != oldValue else { return }
            derivedStatusRevision = UUID()
            derivedStatusFingerprint = ChatStableContentFingerprint(status ?? "")
            derivedStatusWasNil = status == nil
            refreshDisplaySemanticIdentity()
        }
    }
    var modelID: String? {
        didSet {
            guard modelID != oldValue else { return }
            derivedModelIDFingerprint =
                ChatStableContentFingerprint(modelID ?? "")
            derivedModelIDWasNil = modelID == nil
            refreshDisplaySemanticIdentity()
        }
    }
    var eventKind: TatwoNativeChatEventKind = .message {
        didSet {
            guard eventKind != oldValue else { return }
            derivedEventKindFingerprint =
                ChatStableContentFingerprint(eventKind.rawValue)
            refreshDisplaySemanticIdentity()
        }
    }
    var runtimeAdapterID: String? {
        didSet {
            guard runtimeAdapterID != oldValue else { return }
            derivedRuntimeAdapterFingerprint =
                ChatStableContentFingerprint(runtimeAdapterID ?? "")
            derivedRuntimeAdapterWasNil = runtimeAdapterID == nil
            refreshDisplaySemanticIdentity()
        }
    }
    var runtimeFallbackReason: TatwoChatRuntimeFallbackReason? {
        didSet {
            guard runtimeFallbackReason != oldValue else { return }
            derivedRuntimeFallbackFingerprint =
                ChatStableContentFingerprint(
                    runtimeFallbackReason?.rawValue ?? "")
            derivedRuntimeFallbackWasNil = runtimeFallbackReason == nil
            refreshDisplaySemanticIdentity()
        }
    }
    /// Canonical assistant turn identity used to group inline work events with
    /// the final assistant response. Legacy stored rows may not have one.
    var turnID: String? {
        didSet {
            guard turnID != oldValue else { return }
            derivedTurnFingerprint = ChatStableContentFingerprint(turnID ?? "")
            derivedTurnWasNil = turnID == nil
            refreshDisplaySemanticIdentity()
        }
    }
    var planQuestions: [PlanQuestionV1] {
        didSet {
            guard planQuestions != oldValue else { return }
            derivedPlanQuestionsFingerprint =
                ChatMessageSemanticIdentity.planQuestionsFingerprint(
                    planQuestions)
            refreshDisplaySemanticIdentity()
        }
    }
    var createdAt: Date {
        didSet {
            guard createdAt != oldValue else { return }
            refreshDisplaySemanticIdentity()
        }
    }
    /// Copies of an unchanged `ChatMessage` keep the same revision, while direct
    /// streaming mutations receive a new O(1) identity in the property observer.
    private(set) var derivedTextRevision: UUID
    /// Exact mutation provenance for the most recent append. The derived-value
    /// resolver uses the prior revision token rather than comparing a complete
    /// NSString prefix on every streamed token. If an intermediate revision was
    /// not resolved, the cache safely falls back to a full derivation.
    private(set) var derivedTextAppendBaseRevision: UUID?
    private(set) var derivedTextAppendSuffix: String?
    private(set) var derivedStatusRevision: UUID
    /// Stable, fixed-size content guards are computed only on source mutation.
    /// Cache hits compare these values without re-reading or comparing String
    /// storage. Length plus two independent 64-bit accumulators also prevents
    /// same-length edits from aliasing under a single fragile hash.
    private(set) var derivedTextFingerprint: ChatStableContentFingerprint
    private(set) var derivedStatusFingerprint: ChatStableContentFingerprint
    private(set) var derivedStatusWasNil: Bool
    private let derivedIDFingerprint: ChatStableContentFingerprint
    private var derivedModelIDFingerprint: ChatStableContentFingerprint
    private var derivedModelIDWasNil: Bool
    private var derivedEventKindFingerprint: ChatStableContentFingerprint
    private var derivedRuntimeAdapterFingerprint: ChatStableContentFingerprint
    private var derivedRuntimeAdapterWasNil: Bool
    private var derivedRuntimeFallbackFingerprint: ChatStableContentFingerprint
    private var derivedRuntimeFallbackWasNil: Bool
    private var derivedTurnFingerprint: ChatStableContentFingerprint
    private var derivedTurnWasNil: Bool
    private var derivedPlanQuestionsFingerprint:
        ChatStableContentFingerprint
    /// Cached at source mutation time so SwiftUI display fingerprinting never
    /// walks the full transcript text merely to count bytes during `body`.
    private(set) var derivedTextUTF8Count: Int
    /// Covers every semantic field consumed by transcript display projection.
    /// The value is deterministic across reconstructed messages and updates from
    /// mutation-time fingerprints without rescanning accumulated stream text.
    private(set) var displaySemanticIdentity: ChatMessageSemanticIdentity
    /// Deterministic aggregate of the complete visible projection. SwiftUI can
    /// read the tail row and still observe a semantic mutation in any row.
    private(set) var transcriptProjectionRevision:
        ChatTranscriptSemanticRevision
    /// Tail-carried aggregate metadata for body/layout decisions that would
    /// otherwise scan backward for the latest assistant on every render.
    private(set) var transcriptLatestAssistantMessageID: String?
    private(set) var transcriptLatestAssistantHasPlanQuestions: Bool
    /// Byte estimate for the complete visible projection, carried only by the
    /// tail row. This lets the outer cache account a streaming suffix without
    /// rescanning every retained String on each token.
    private(set) var transcriptProjectionResidentBytes: Int
    /// Suppresses the general full replacement observer only while the
    /// dedicated streaming append primitive updates the String and fingerprint
    /// together. This flag is cache metadata and is excluded from equality.
    private var isApplyingIncrementalTextAppend: Bool

    init(
        id: String = UUID().uuidString,
        role: ChatMessageRole,
        text: String,
        status: String? = nil,
        modelID: String? = nil,
        eventKind: TatwoNativeChatEventKind = .message,
        runtimeAdapterID: String? = nil,
        runtimeFallbackReason: TatwoChatRuntimeFallbackReason? = nil,
        turnID: String? = nil,
        planQuestions: [PlanQuestionV1] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
        self.modelID = modelID
        self.eventKind = eventKind
        self.runtimeAdapterID = runtimeAdapterID
        self.runtimeFallbackReason = runtimeFallbackReason
        self.turnID = turnID
        self.planQuestions = planQuestions
        self.createdAt = createdAt
        self.derivedTextRevision = UUID()
        self.derivedTextAppendBaseRevision = nil
        self.derivedTextAppendSuffix = nil
        self.derivedStatusRevision = UUID()
        let textFingerprint = ChatStableContentFingerprint(text)
        let statusFingerprint = ChatStableContentFingerprint(status ?? "")
        let idFingerprint = ChatStableContentFingerprint(id)
        let modelIDFingerprint = ChatStableContentFingerprint(modelID ?? "")
        let eventKindFingerprint =
            ChatStableContentFingerprint(eventKind.rawValue)
        let runtimeAdapterFingerprint =
            ChatStableContentFingerprint(runtimeAdapterID ?? "")
        let runtimeFallbackFingerprint =
            ChatStableContentFingerprint(
                runtimeFallbackReason?.rawValue ?? "")
        let turnFingerprint = ChatStableContentFingerprint(turnID ?? "")
        let planQuestionsFingerprint =
            ChatMessageSemanticIdentity.planQuestionsFingerprint(planQuestions)
        self.derivedTextFingerprint = textFingerprint
        self.derivedStatusFingerprint = statusFingerprint
        self.derivedStatusWasNil = status == nil
        self.derivedIDFingerprint = idFingerprint
        self.derivedModelIDFingerprint = modelIDFingerprint
        self.derivedModelIDWasNil = modelID == nil
        self.derivedEventKindFingerprint = eventKindFingerprint
        self.derivedRuntimeAdapterFingerprint = runtimeAdapterFingerprint
        self.derivedRuntimeAdapterWasNil = runtimeAdapterID == nil
        self.derivedRuntimeFallbackFingerprint =
            runtimeFallbackFingerprint
        self.derivedRuntimeFallbackWasNil = runtimeFallbackReason == nil
        self.derivedTurnFingerprint = turnFingerprint
        self.derivedTurnWasNil = turnID == nil
        self.derivedPlanQuestionsFingerprint = planQuestionsFingerprint
        self.derivedTextUTF8Count = textFingerprint.utf8Count
        self.displaySemanticIdentity = ChatMessageSemanticIdentity(
            idFingerprint: idFingerprint,
            role: role,
            textFingerprint: textFingerprint,
            statusFingerprint: statusFingerprint,
            statusWasNil: status == nil,
            modelIDFingerprint: modelIDFingerprint,
            modelIDWasNil: modelID == nil,
            eventKindFingerprint: eventKindFingerprint,
            runtimeAdapterFingerprint: runtimeAdapterFingerprint,
            runtimeAdapterWasNil: runtimeAdapterID == nil,
            runtimeFallbackFingerprint: runtimeFallbackFingerprint,
            runtimeFallbackWasNil: runtimeFallbackReason == nil,
            turnFingerprint: turnFingerprint,
            turnWasNil: turnID == nil,
            planQuestionsFingerprint: planQuestionsFingerprint,
            createdAt: createdAt)
        self.transcriptProjectionRevision = .empty
        self.transcriptLatestAssistantMessageID =
            role == .assistant ? id : nil
        self.transcriptLatestAssistantHasPlanQuestions =
            role == .assistant && !planQuestions.isEmpty
        self.transcriptProjectionResidentBytes = 0
        self.isApplyingIncrementalTextAppend = false
    }

    mutating func appendTranscriptText(_ suffix: String) {
        guard !suffix.isEmpty else { return }
        let appendBaseRevision = derivedTextRevision
        let updatedFingerprint = derivedTextFingerprint.appending(suffix)
        isApplyingIncrementalTextAppend = true
        text.append(contentsOf: suffix)
        isApplyingIncrementalTextAppend = false
        derivedTextRevision = UUID()
        derivedTextAppendBaseRevision = appendBaseRevision
        derivedTextAppendSuffix = suffix
        derivedTextFingerprint = updatedFingerprint
        derivedTextUTF8Count = updatedFingerprint.utf8Count
        refreshDisplaySemanticIdentity()
    }

    mutating func assignTranscriptProjectionMetadata(
        revision: ChatTranscriptSemanticRevision,
        latestAssistantMessageID: String?,
        latestAssistantHasPlanQuestions: Bool,
        residentBytes: Int
    ) {
        transcriptProjectionRevision = revision
        transcriptLatestAssistantMessageID = latestAssistantMessageID
        transcriptLatestAssistantHasPlanQuestions =
            latestAssistantHasPlanQuestions
        transcriptProjectionResidentBytes = residentBytes
    }

    private mutating func refreshDisplaySemanticIdentity() {
        displaySemanticIdentity = ChatMessageSemanticIdentity(
            idFingerprint: derivedIDFingerprint,
            role: role,
            textFingerprint: derivedTextFingerprint,
            statusFingerprint: derivedStatusFingerprint,
            statusWasNil: derivedStatusWasNil,
            modelIDFingerprint: derivedModelIDFingerprint,
            modelIDWasNil: derivedModelIDWasNil,
            eventKindFingerprint: derivedEventKindFingerprint,
            runtimeAdapterFingerprint: derivedRuntimeAdapterFingerprint,
            runtimeAdapterWasNil: derivedRuntimeAdapterWasNil,
            runtimeFallbackFingerprint: derivedRuntimeFallbackFingerprint,
            runtimeFallbackWasNil: derivedRuntimeFallbackWasNil,
            turnFingerprint: derivedTurnFingerprint,
            turnWasNil: derivedTurnWasNil,
            planQuestionsFingerprint: derivedPlanQuestionsFingerprint,
            createdAt: createdAt)
    }

    /// The revision tokens above are cache/lifecycle metadata, not message
    /// semantics. Keep equality compatible with the pre-cache ChatMessage so a
    /// rehydrated but otherwise identical row does not become spuriously unequal.
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.status == rhs.status
            && lhs.modelID == rhs.modelID
            && lhs.eventKind == rhs.eventKind
            && lhs.runtimeAdapterID == rhs.runtimeAdapterID
            && lhs.runtimeFallbackReason == rhs.runtimeFallbackReason
            && lhs.turnID == rhs.turnID
            && lhs.planQuestions == rhs.planQuestions
            && lhs.createdAt == rhs.createdAt
    }
}

struct ChatTranscriptProjectionCacheKey: Equatable {
    let selectedSessionStableKey: String?
    let liveMessagesRevision: UInt64
    let journalRevision: UInt64
    let documentRevision: UInt64
    let journalPersistenceAllowed: Bool
    let legacyMigrationCompleted: Bool
}

struct ChatTranscriptProjectionCacheMetrics: Equatable {
    var hits = 0
    var misses = 0
    var recomputations = 0
    var incrementalUpdates = 0
    var liveIdentityEvaluations = 0
    var liveMessageEvaluations = 0
    var liveResidentByteEvaluations = 0
    var liveMetadataAssignments = 0
    var fullProjectionResidentScans = 0
    var evictions = 0
    var cachedSessionCount = 0
    var residentBytes = 0
}

/// Small session-bounded projection cache scoped to a `ChatPageModel`.
///
/// Switching threads must not destroy every reusable projection: returning to
/// a long transcript would otherwise guarantee another filter/parse pass. The
/// cache keeps only a handful of sessions and updates only the changed suffix
/// inside each session.
final class ChatTranscriptProjectionCache {
    private struct SessionIdentity: Hashable {
        let stableKey: String?
    }

    struct LiveMessageIdentity: Equatable {
        let semanticIdentity: ChatMessageSemanticIdentity

        init(_ message: ChatMessage) {
            semanticIdentity = message.displaySemanticIdentity
        }
    }

    private struct ProjectionEntry {
        var key: ChatTranscriptProjectionCacheKey
        var messages: [ChatMessage]
        var residentBytes: Int
    }

    private struct LiveEntry {
        var includeRevision: UInt64 = 0
        var identities: [LiveMessageIdentity] = []
        var messages: [ChatMessage] = []
        var inclusion: [Bool] = []
        var projection: [ChatMessage] = []
        var messageResidentBytes: [Int] = []
        var prefixResidentByteTotals: [Int] = []
        var prefixProjectionRevisions: [ChatTranscriptSemanticRevision] = []
        var prefixLatestAssistantMessageIDs: [String?] = []
        var prefixLatestAssistantHasPlanQuestions: [Bool] = []
        var residentBytes = 0
    }

    let maximumSessionCount: Int
    let maximumResidentBytes: Int
    private var projectionEntries: [SessionIdentity: ProjectionEntry] = [:]
    private var liveEntries: [SessionIdentity: LiveEntry] = [:]
    private var recentSessions: [SessionIdentity] = []
    private var residentByteCount = 0
    private(set) var metrics = ChatTranscriptProjectionCacheMetrics()

    init(
        maximumSessionCount: Int = 8,
        maximumResidentBytes: Int = 24 * 1_024 * 1_024
    ) {
        self.maximumSessionCount = max(1, maximumSessionCount)
        self.maximumResidentBytes = max(1, maximumResidentBytes)
    }

    func resolve(
        key: ChatTranscriptProjectionCacheKey,
        build: () -> [ChatMessage]
    ) -> [ChatMessage] {
        let session = SessionIdentity(stableKey: key.selectedSessionStableKey)
        if let cached = projectionEntries[session],
           cached.key == key
        {
            metrics.hits += 1
            touch(session)
            return cached.messages
        }
        metrics.misses += 1
        metrics.recomputations += 1
        var messages = build()
        let hasLiveMetadata =
            messages.last?.transcriptProjectionRevision.messageCount
                == messages.count
        let residentBytes: Int
        if !messages.isEmpty, !hasLiveMetadata {
            let semanticRevision = ChatTranscriptSemanticRevision(messages)
            let latestAssistant =
                messages.last(where: { $0.role == .assistant })
            residentBytes = Self.estimatedResidentBytes(for: messages)
            metrics.fullProjectionResidentScans += 1
            messages[messages.count - 1]
                .assignTranscriptProjectionMetadata(
                    revision: semanticRevision,
                    latestAssistantMessageID: latestAssistant?.id,
                    latestAssistantHasPlanQuestions:
                        latestAssistant?.planQuestions.isEmpty == false,
                    residentBytes: residentBytes)
        } else {
            residentBytes =
                messages.last?.transcriptProjectionResidentBytes ?? 0
        }
        if let previous = projectionEntries[session] {
            residentByteCount -= previous.residentBytes
        }
        projectionEntries[session] = ProjectionEntry(
            key: key,
            messages: messages,
            residentBytes: residentBytes)
        residentByteCount += residentBytes
        touch(session)
        evictIfNeeded(protecting: session)
        return messages
    }

    /// Rebuilds only the changed suffix of the live projection. Streaming
    /// normally mutates the last assistant row, so prior messages retain their
    /// exact String/value storage and only one row re-runs transcript parsing.
    func resolveLive(
        sessionKey: String?,
        messages: [ChatMessage],
        includeRevision: UInt64 = 1,
        include: (ChatMessage) -> Bool
    ) -> [ChatMessage] {
        let session = SessionIdentity(stableKey: sessionKey)
        var entry = liveEntries[session] ?? LiveEntry()
        let comparableCount = min(
            messages.count,
            entry.identities.count)
        var unchangedPrefixCount = 0
        if entry.includeRevision == includeRevision {
            while unchangedPrefixCount < comparableCount,
                  messages[unchangedPrefixCount].displaySemanticIdentity
                    == entry.identities[unchangedPrefixCount].semanticIdentity
            {
                unchangedPrefixCount += 1
            }
        }
        if unchangedPrefixCount == messages.count,
           unchangedPrefixCount == entry.identities.count,
           entry.includeRevision == includeRevision
        {
            touch(session)
            return entry.projection
        }

        var projection: [ChatMessage] = []
        projection.reserveCapacity(messages.count)
        if unchangedPrefixCount > 0 {
            for index in 0..<unchangedPrefixCount
                where entry.inclusion[index]
            {
                projection.append(entry.messages[index])
            }
            metrics.incrementalUpdates += 1
        }

        var inclusion = Array(
            entry.inclusion.prefix(unchangedPrefixCount))
        inclusion.reserveCapacity(messages.count)
        var identities = Array(
            entry.identities.prefix(unchangedPrefixCount))
        identities.reserveCapacity(messages.count)
        var messageResidentBytes = Array(
            entry.messageResidentBytes.prefix(unchangedPrefixCount))
        messageResidentBytes.reserveCapacity(messages.count)
        var prefixResidentByteTotals = Array(
            entry.prefixResidentByteTotals.prefix(unchangedPrefixCount))
        prefixResidentByteTotals.reserveCapacity(messages.count)
        var prefixProjectionRevisions = Array(
            entry.prefixProjectionRevisions.prefix(unchangedPrefixCount))
        prefixProjectionRevisions.reserveCapacity(messages.count)
        var prefixLatestAssistantMessageIDs = Array(
            entry.prefixLatestAssistantMessageIDs.prefix(unchangedPrefixCount))
        prefixLatestAssistantMessageIDs.reserveCapacity(messages.count)
        var prefixLatestAssistantHasPlanQuestions = Array(
            entry.prefixLatestAssistantHasPlanQuestions
                .prefix(unchangedPrefixCount))
        prefixLatestAssistantHasPlanQuestions.reserveCapacity(messages.count)
        var messageResidentByteTotal =
            prefixResidentByteTotals.last ?? 0
        var projectionRevision =
            prefixProjectionRevisions.last ?? .empty
        var latestAssistantMessageID =
            prefixLatestAssistantMessageIDs.last ?? nil
        var latestAssistantHasPlanQuestions =
            prefixLatestAssistantHasPlanQuestions.last ?? false
        for index in unchangedPrefixCount..<messages.count {
            identities.append(LiveMessageIdentity(messages[index]))
            metrics.liveIdentityEvaluations += 1
            let isIncluded = include(messages[index])
            inclusion.append(isIncluded)
            metrics.liveMessageEvaluations += 1
            let rowResidentBytes =
                Self.estimatedResidentBytes(for: messages[index])
            messageResidentBytes.append(rowResidentBytes)
            messageResidentByteTotal += rowResidentBytes
            prefixResidentByteTotals.append(messageResidentByteTotal)
            metrics.liveResidentByteEvaluations += 1
            if isIncluded {
                projection.append(messages[index])
                projectionRevision = projectionRevision.appending(
                    messages[index].displaySemanticIdentity)
                if messages[index].role == .assistant {
                    latestAssistantMessageID = messages[index].id
                    latestAssistantHasPlanQuestions =
                        !messages[index].planQuestions.isEmpty
                }
            }
            prefixProjectionRevisions.append(projectionRevision)
            prefixLatestAssistantMessageIDs.append(
                latestAssistantMessageID)
            prefixLatestAssistantHasPlanQuestions.append(
                latestAssistantHasPlanQuestions)
        }

        let projectionResidentBytes =
            messageResidentByteTotal
            + MemoryLayout<LiveMessageIdentity>.stride * identities.count
            + MemoryLayout<Bool>.stride * inclusion.count
            + MemoryLayout<ChatMessage>.stride * projection.count
            + MemoryLayout<Int>.stride
                * (messageResidentBytes.count
                    + prefixResidentByteTotals.count)
            + MemoryLayout<ChatTranscriptSemanticRevision>.stride
                * prefixProjectionRevisions.count
            + MemoryLayout<String?>.stride
                * prefixLatestAssistantMessageIDs.count
            + MemoryLayout<Bool>.stride
                * prefixLatestAssistantHasPlanQuestions.count
        if !projection.isEmpty {
            projection[projection.count - 1]
                .assignTranscriptProjectionMetadata(
                    revision: projectionRevision,
                    latestAssistantMessageID: latestAssistantMessageID,
                    latestAssistantHasPlanQuestions:
                        latestAssistantHasPlanQuestions,
                    residentBytes: projectionResidentBytes)
            metrics.liveMetadataAssignments += 1
        }

        entry.includeRevision = includeRevision
        entry.identities = identities
        entry.messages = messages
        entry.inclusion = inclusion
        entry.projection = projection
        entry.messageResidentBytes = messageResidentBytes
        entry.prefixResidentByteTotals = prefixResidentByteTotals
        entry.prefixProjectionRevisions = prefixProjectionRevisions
        entry.prefixLatestAssistantMessageIDs =
            prefixLatestAssistantMessageIDs
        entry.prefixLatestAssistantHasPlanQuestions =
            prefixLatestAssistantHasPlanQuestions
        entry.residentBytes = projectionResidentBytes
        if let previous = liveEntries[session] {
            residentByteCount -= previous.residentBytes
        }
        liveEntries[session] = entry
        residentByteCount += entry.residentBytes
        touch(session)
        evictIfNeeded(protecting: session)
        return projection
    }

    func reset() {
        projectionEntries.removeAll(keepingCapacity: true)
        liveEntries.removeAll(keepingCapacity: true)
        recentSessions.removeAll(keepingCapacity: true)
        residentByteCount = 0
        metrics = ChatTranscriptProjectionCacheMetrics()
    }

    private func touch(_ session: SessionIdentity) {
        if let index = recentSessions.firstIndex(of: session) {
            recentSessions.remove(at: index)
        }
        recentSessions.append(session)
        metrics.cachedSessionCount = recentSessions.count
        metrics.residentBytes = residentByteCount
    }

    private func evictIfNeeded(protecting activeSession: SessionIdentity) {
        while recentSessions.count > maximumSessionCount
            || residentByteCount > maximumResidentBytes
        {
            guard let evictionIndex = recentSessions.firstIndex(
                where: { $0 != activeSession })
            else {
                // A single active transcript may itself exceed the ceiling.
                // Keep it usable instead of forcing a parse on every body pass.
                break
            }
            let evicted = recentSessions.remove(at: evictionIndex)
            removeEntries(for: evicted)
            metrics.evictions += 1
        }
        metrics.cachedSessionCount = recentSessions.count
        metrics.residentBytes = residentByteCount
    }

    private func removeEntries(for session: SessionIdentity) {
        if let removed = projectionEntries.removeValue(forKey: session) {
            residentByteCount -= removed.residentBytes
        }
        if let removed = liveEntries.removeValue(forKey: session) {
            residentByteCount -= removed.residentBytes
        }
        residentByteCount = max(0, residentByteCount)
    }

    private static func estimatedResidentBytes(
        for messages: [ChatMessage]
    ) -> Int {
        messages.reduce(
            into: MemoryLayout<ChatMessage>.stride * messages.count
        ) { total, message in
            total += estimatedResidentBytes(for: message)
        }
    }

    private static func estimatedResidentBytes(
        for message: ChatMessage
    ) -> Int {
        var total =
            message.id.utf8.count
            + message.derivedTextUTF8Count
            + (message.status?.utf8.count ?? 0)
            + (message.modelID?.utf8.count ?? 0)
            + (message.runtimeAdapterID?.utf8.count ?? 0)
            + (message.turnID?.utf8.count ?? 0)
            + MemoryLayout<PlanQuestionV1>.stride
                * message.planQuestions.count
        for question in message.planQuestions {
            total += question.id.utf8.count
            total += question.question.utf8.count
            total += MemoryLayout<PlanQuestionV1.Option>.stride
                * question.options.count
            for option in question.options {
                total += option.label.utf8.count
                total += option.detail.utf8.count
            }
        }
        return total
    }
}

struct ChatTranscriptDisplayFingerprint: Equatable {
    var count: Int
    var lastID: String
    var lastTextUTF8Count: Int
    var lastDisplaySemanticIdentity: ChatMessageSemanticIdentity?
    var projectionRevision: ChatTranscriptSemanticRevision?
    /// The full transcript semantic revision is also the authority for
    /// presentation-only folding of confirmed Plan execution envelopes.
    /// Keeping this dependency explicit prevents a cached display tree from
    /// surviving when an older execution row changes while the tail row does
    /// not.
    var foldedExecutionProjectionRevision: ChatTranscriptSemanticRevision?
    var fallbackFoldedExecutionIdentity: ChatMessageSemanticIdentity?
    var planArtifactSourceMessageID: String?
    var activePlanTurnAssistantMessageID: String?
    var isPlanWriting: Bool
    var latestAssistantMessageID: String?
    var latestAssistantHasPlanQuestions: Bool
    /// Test-visible operation contract: a non-empty render key reads only the
    /// projected tail row, regardless of transcript length.
    var inspectedRowCount: Int

    init() {
        count = 0
        lastID = ""
        lastTextUTF8Count = 0
        lastDisplaySemanticIdentity = nil
        projectionRevision = nil
        foldedExecutionProjectionRevision = nil
        fallbackFoldedExecutionIdentity = nil
        planArtifactSourceMessageID = nil
        activePlanTurnAssistantMessageID = nil
        isPlanWriting = false
        latestAssistantMessageID = nil
        latestAssistantHasPlanQuestions = false
        inspectedRowCount = 0
    }

    init(
        _ messages: [ChatMessage],
        planArtifactSourceMessageID: String? = nil,
        activePlanTurnAssistantMessageID: String? = nil,
        isPlanWriting: Bool = false
    ) {
        count = messages.count
        self.planArtifactSourceMessageID = planArtifactSourceMessageID
        self.activePlanTurnAssistantMessageID =
            activePlanTurnAssistantMessageID
        self.isPlanWriting = isPlanWriting
        if let last = messages.last {
            lastID = last.id
            lastTextUTF8Count = last.derivedTextUTF8Count
            lastDisplaySemanticIdentity = last.displaySemanticIdentity
            projectionRevision = last.transcriptProjectionRevision
            foldedExecutionProjectionRevision =
                last.transcriptProjectionRevision
            fallbackFoldedExecutionIdentity =
                last.transcriptProjectionRevision == .empty
                ? messages.last(where: {
                    ChatPlanThoughtPresentation
                        .isConfirmedPlanExecutionPrompt($0)
                })?.displaySemanticIdentity
                : nil
            latestAssistantMessageID =
                last.transcriptLatestAssistantMessageID
            latestAssistantHasPlanQuestions =
                last.transcriptLatestAssistantHasPlanQuestions
            inspectedRowCount = 1
        } else {
            lastID = ""
            lastTextUTF8Count = 0
            lastDisplaySemanticIdentity = nil
            projectionRevision = nil
            foldedExecutionProjectionRevision = nil
            fallbackFoldedExecutionIdentity = nil
            latestAssistantMessageID = nil
            latestAssistantHasPlanQuestions = false
            inspectedRowCount = 0
        }
    }
}

/// Presentation-only folding for Plan turns.
///
/// The canonical transcript and Plan artifact keep their full payloads for
/// execution, export, and the Plan inspector. The main transcript receives a
/// stable, content-free activity projection so a generated Plan or the App's
/// confirmed-plan execution envelope cannot duplicate many screens of text.
enum ChatPlanThoughtPresentation {
    static let accessibilityLabel = "思考中"

    private enum FoldedStatusPolicy: Equatable {
        case planArtifact
        case confirmedExecution
    }

    private static let confirmedExecutionPrefix =
        "依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。"
    private static let confirmedExecutionToolRequirement =
        "必須使用可用工具直接執行計畫"
    private static let confirmedExecutionPlanMarker = "# Plan"

    static func projectedMessages(
        _ messages: [ChatMessage],
        planArtifactSourceMessageID: String?,
        activePlanTurnAssistantMessageID: String? = nil
    ) -> [ChatMessage] {
        messages.map {
            projectedMessage(
                $0,
                planArtifactSourceMessageID: planArtifactSourceMessageID,
                activePlanTurnAssistantMessageID:
                    activePlanTurnAssistantMessageID)
        }
    }

    static func projectedMessage(
        _ message: ChatMessage,
        planArtifactSourceMessageID: String?,
        activePlanTurnAssistantMessageID: String? = nil
    ) -> ChatMessage {
        if isConfirmedPlanExecutionPrompt(message) {
            return foldedMessage(
                message,
                statusDetail: "已送交 Work OS",
                statusPolicy: .confirmedExecution)
        }
        let isActivePlanTurn =
            message.id == activePlanTurnAssistantMessageID
        guard (message.id == planArtifactSourceMessageID || isActivePlanTurn),
              message.role == .assistant,
              message.eventKind == .message
        else {
            return message
        }
        return foldedMessage(
            message,
            statusDetail: isActivePlanTurn ? "計畫整理中" : "計畫已整理",
            statusPolicy: .planArtifact)
    }

    static func isConfirmedPlanExecutionPrompt(
        _ message: ChatMessage
    ) -> Bool {
        guard message.role == .user,
              message.eventKind == .message
        else {
            return false
        }
        let text = message.text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.hasPrefix(confirmedExecutionPrefix)
            && text.contains(confirmedExecutionToolRequirement)
            && text.contains(confirmedExecutionPlanMarker)
    }

    private static func foldedMessage(
        _ source: ChatMessage,
        statusDetail: String,
        statusPolicy: FoldedStatusPolicy
    ) -> ChatMessage {
        ChatMessage(
            id: source.id,
            role: .assistant,
            text: "",
            status: foldedStatus(
                source.status,
                detail: statusDetail,
                policy: statusPolicy),
            modelID: source.modelID,
            eventKind: .thinking,
            runtimeAdapterID: source.runtimeAdapterID,
            runtimeFallbackReason: source.runtimeFallbackReason,
            turnID: source.turnID,
            planQuestions: [],
            createdAt: source.createdAt)
    }

    private static func foldedStatus(
        _ status: String?,
        detail: String,
        policy: FoldedStatusPolicy
    ) -> String {
        let normalized = status?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = normalized.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false)
        let base = components.first.map {
            String($0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } ?? ""
        let sourceDetail = components.dropFirst().first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }
        if base.isEmpty, policy == .confirmedExecution {
            return "queued|已送交 Work OS／等待 runner"
        }
        if ["queued", "pending", "waiting"].contains(base) {
            return "queued|\(detail)"
        }
        if ["stream", "streaming", "thinking", "working", "planning"]
            .contains(base)
        {
            return "planning|\(detail)"
        }
        if base.hasPrefix("fail")
            || base.hasPrefix("error")
            || base == "blocked"
            || base == "route-blocked"
        {
            return "failed|\(sourceDetail ?? detail)"
        }
        if ["stopped", "cancelled", "canceled"].contains(base) {
            return "stopped|\(sourceDetail ?? detail)"
        }
        if ["completed", "done", "succeeded", "success"].contains(base) {
            return "completed|\(sourceDetail ?? detail)"
        }
        if policy == .confirmedExecution {
            return "queued|\(sourceDetail ?? "已送交 Work OS／等待 runner")"
        }
        return "completed|\(detail)"
    }
}

struct ChatPlanTurnBinding: Sendable, Equatable {
    let threadID: UUID
    let sourceUserMessageID: ChatMessage.ID
    let assistantMessageID: ChatMessage.ID
    let objectiveCandidate: String?
    let startingPlanID: UUID?
    let startingObjective: String?
    let startingArtifactUpdatedAt: Date?

    func matchesStartingArtifact(_ artifact: TatwoPlanArtifactV1?) -> Bool {
        artifact?.planID == startingPlanID
            && artifact?.objective == startingObjective
            && artifact?.updatedAt == startingArtifactUpdatedAt
    }
}

enum ChatPlanRevisionIntent {
    static func objectiveCandidate(
        userTurn: String,
        pendingObjective: String?,
        existingObjective: String?
    ) -> String? {
        if let pending = normalized(pendingObjective), !pending.isEmpty {
            return pending
        }
        guard let turn = normalized(userTurn), !turn.isEmpty else {
            return nil
        }
        guard existingObjective != nil else { return turn }

        let lower = turn.lowercased()
        let planAnchors = [
            "/plan", "計畫", "規劃", "plan", "goal", "目標", "work os",
            "送交 work os",
        ]
        let revisionOrTransitionVerbs = [
            "重設", "重新", "更新", "修改", "改成", "改寫", "替換", "建立",
            "執行", "送交", "確認", "replan", "revise", "update", "replace",
            "reset", "create", "execute", "submit", "confirm",
        ]
        guard planAnchors.contains(where: lower.contains),
              revisionOrTransitionVerbs.contains(where: lower.contains)
        else {
            return nil
        }
        return turn
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ChatHandoffMessage: Codable, Equatable {
    var role: String
    var text: String
    var status: String?
    var modelID: String?
    var eventKind: TatwoNativeChatEventKind
}

struct ChatHandoffEnvelope: Codable, Equatable {
    var schemaVersion: Int
    var exportedAt: Date
    var source: String
    var projectName: String
    var threadID: UUID?
    var threadTitle: String
    var messageCount: Int
    var messages: [ChatHandoffMessage]
    var loopsConfig: TatwoNativeThreadLoopsConfig?

    var summaryLine: String {
        let loops = loopsConfig?.summaryLine ?? "no loopsConfig"
        return "\(threadTitle.isEmpty ? "未命名 thread" : threadTitle) · \(messageCount)則 · \(loops)"
    }
}

extension ChatMessage {
    init(stored record: TatwoNativeChatStoredMessage) {
        self.init(
            id: record.id,
            role: ChatMessageRole.storageValue(record.role),
            text: record.text,
            status: record.status,
            modelID: record.modelID,
            eventKind: record.eventKind,
            runtimeAdapterID: record.runtimeAdapterID,
            runtimeFallbackReason: record.runtimeFallbackReason,
            createdAt: record.createdAt)
    }

    var storedRecord: TatwoNativeChatStoredMessage {
        TatwoNativeChatStoredMessage(
            id: id,
            role: role.storageValue,
            text: text,
            status: status,
            modelID: modelID,
            eventKind: eventKind,
            runtimeAdapterID: runtimeAdapterID,
            runtimeFallbackReason: runtimeFallbackReason,
            createdAt: createdAt)
    }
}

struct ChatQueuedTicket: Identifiable {
    let id = UUID()
    let threadID: UUID?
    let discussionID: UUID?
    let messageID: ChatMessage.ID
    let displayTurn: String
    /// Per-turn hidden policy/contract context without transcript history.
    ///
    /// Transcript history is recomposed when the ticket reaches the front of
    /// the queue. Capturing it here both duplicates large strings in memory
    /// and misses assistant replies that finish while this ticket is waiting.
    let commandBaseTurn: String
    let visibleTurn: String
    let attachmentPaths: [String]
    let preview: String
    /// Immutable route/contract/effort snapshot captured at enqueue time.
    /// Changing the model picker or effort control later must not rewrite it.
    let dispatchSnapshot: ChatTurnDispatchSnapshot

    var residentUTF8Bytes: Int {
        displayTurn.utf8.count
            + commandBaseTurn.utf8.count
            + visibleTurn.utf8.count
            + preview.utf8.count
            + dispatchSnapshot.routeID.utf8.count
            + dispatchSnapshot.canonicalModelID.utf8.count
            + (dispatchSnapshot.vendorModelID?.utf8.count ?? 0)
            + (dispatchSnapshot.contractID?.utf8.count ?? 0)
            + (dispatchSnapshot.contractBindingID?.utf8.count ?? 0)
            + (dispatchSnapshot.requestedEffort?.rawValue.utf8.count ?? 0)
            + (dispatchSnapshot.forwardedEffort?.rawValue.utf8.count ?? 0)
            + dispatchSnapshot.effortOutcome.rawValue.utf8.count
            + (dispatchSnapshot.blocker?.utf8.count ?? 0)
            + dispatchSnapshot.computerHostDecision.route.rawValue.utf8.count
            + attachmentPaths.reduce(into: 0) { bytes, path in
                bytes += path.utf8.count
            }
    }
}

enum ChatQueueContextPolicy {
    static func transcriptForExecution(
        messages: [ChatMessage],
        currentMessageID: ChatMessage.ID,
        pendingMessageIDs: Set<ChatMessage.ID>
    ) -> [TatwoNativeChatStoredMessage] {
        messages.compactMap { message in
            guard message.id != currentMessageID,
                  message.status != "queued",
                  !pendingMessageIDs.contains(message.id)
            else {
                return nil
            }
            return message.storedRecord
        }
    }
}

struct ChatLiveWorkActivity: Identifiable, Equatable {
    let id: UUID
    let label: String
    let detail: String?
    let systemImage: String
    let isTerminal: Bool
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        detail: String? = nil,
        systemImage: String,
        isTerminal: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.systemImage = systemImage
        self.isTerminal = isTerminal
        self.updatedAt = updatedAt
    }
}
