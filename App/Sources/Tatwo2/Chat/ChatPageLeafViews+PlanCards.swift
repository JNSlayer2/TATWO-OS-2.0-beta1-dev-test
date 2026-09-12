// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageLeafViews+PlanCards.swift；改動 4 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import AppKit
import Foundation
import QuickLook

struct PlanClarificationRequestCard: View {
    let questions: [PlanQuestionV1]
    let isLatestAssistantMessage: Bool
    let initialFocusAlreadyClaimed: Bool
    let onInitialFocusClaimed: () -> Void

    @State private var questionIndex = 0
    @State private var selections: [String: Set<String>] = [:]
    @State private var selectionOrders: [String: [String]] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var skippedQuestionIDs: Set<String> = []
    @State private var explicitlyAnsweredQuestionIDs: Set<String> = []
    @State private var focusedOptionIndex = 0
    @State private var focusedOptionIndices: [String: Int] = [:]
    @State private var dismissed = false
    @State private var autoAdvanceGeneration = 0
    @State private var autoAdvancePending = false
    @State private var isOtherHovered = false
    @State private var otherEditorHeight: CGFloat = 0
    @State private var isOtherFocused = false
    @State private var focusRestoreGeneration = 0
    @State private var isRestoringCardFocus = false
    @State private var restoreCardFocusWhenOtherBlurs = false
    @FocusState private var isCardFocused: Bool

    private let otherEditorMinimumHeight =
        PlanClarificationCodexPresentation.otherEditorMinimumHeight
    private let otherEditorMaximumHeight =
        PlanClarificationCodexPresentation.otherEditorMaximumHeight

    init(
        questions: [PlanQuestionV1],
        isLatestAssistantMessage: Bool,
        initialFocusAlreadyClaimed: Bool,
        onInitialFocusClaimed: @escaping () -> Void
    ) {
        self.questions = questions
        self.isLatestAssistantMessage = isLatestAssistantMessage
        self.initialFocusAlreadyClaimed = initialFocusAlreadyClaimed
        self.onInitialFocusClaimed = onInitialFocusClaimed
        _selections = State(
            initialValue: Self.initializeSelections(for: questions))
        let initialFocus = Self.initializeFocusedOptionIndices(for: questions)
        _focusedOptionIndices = State(initialValue: initialFocus)
        _focusedOptionIndex = State(
            initialValue: questions.first.flatMap { initialFocus[$0.id] } ?? -1)
    }

    private static func initializeSelections(
        for questions: [PlanQuestionV1]
    ) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: questions.compactMap { question in
            guard !question.allowsMultipleSelections,
                  let firstOption = question.options.first
            else { return nil }
            return (question.id, [firstOption.label])
        })
    }

    private static func initializeFocusedOptionIndices(
        for questions: [PlanQuestionV1]
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: questions.map { question in
            (
                question.id,
                PlanClarificationInteractionPolicy.initialFocusedOptionIndex(
                    allowsMultipleSelections:
                        question.allowsMultipleSelections,
                    optionCount: question.options.count)
            )
        })
    }

    private var currentQuestion: PlanQuestionV1? {
        guard questions.indices.contains(questionIndex) else { return nil }
        return questions[questionIndex]
    }

    var body: some View {
        if !dismissed, let question = currentQuestion {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(question.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    if questions.count > 1 {
                        HStack(spacing: 4) {
                            Button {
                                navigateQuestionAndRestoreFocus(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .disabled(questionIndex == 0)
                            .accessibilityLabel("Previous question")
                            .accessibilityIdentifier(
                                "chat-plan-question-previous")

                            Text("\(questionIndex + 1) of \(questions.count)")
                                .font(.system(
                                    size: PlanClarificationCodexPresentation
                                        .counterPointSize))
                                .foregroundStyle(.tertiary)

                            Button {
                                navigateQuestionAndRestoreFocus(by: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .disabled(questionIndex == questions.count - 1)
                            .accessibilityLabel("Next question")
                            .accessibilityIdentifier(
                                "chat-plan-question-next")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.top, 16)
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(
                            Array(question.options.enumerated()),
                            id: \.element.label
                        ) { index, option in
                            optionButton(
                                option,
                                number: index + 1,
                                isFocused: focusedOptionIndex == index,
                                question: question)
                        }
                    }

                    HStack(spacing: 8) {
                        if question.allowsOtherResponse {
                            otherMarker(for: question)
                            ChatComposerTextView(
                                text: draftBinding(for: question.id),
                                contentHeight: $otherEditorHeight,
                                isFocused: isOtherFocused,
                                placeholder:
                                    PlanClarificationCodexPresentation
                                        .defaultOtherPlaceholder,
                                isMonospaced: false,
                                minimumHeight: otherEditorMinimumHeight,
                                maximumHeight: otherEditorMaximumHeight,
                                onSubmit: {
                                    handleOtherReturnKey()
                                },
                                onFocusChange: { focused in
                                    if focused {
                                        focusOther(in: question)
                                    } else {
                                        isOtherFocused = false
                                        if restoreCardFocusWhenOtherBlurs {
                                            restoreCardFocusWhenOtherBlurs =
                                                false
                                            if !dismissed {
                                                restoreCardFocusAfterAction()
                                            }
                                        }
                                    }
                                },
                                onSuggestionKey: nil,
                                onPasteImage: nil,
                                accessibilityTextLabel:
                                    PlanClarificationCodexPresentation
                                        .defaultOtherPlaceholder,
                                onArrowUpAtSingleVisualLine: {
                                    handleOtherArrowUp()
                                },
                                allowsProgrammaticBlur: true,
                                resignsFocusOnSubmit: true,
                                pointSize:
                                    PlanClarificationCodexPresentation
                                        .optionPointSize,
                                slashCommands: [])
                                .frame(
                                    height: min(
                                        otherEditorMaximumHeight,
                                        max(
                                            otherEditorMinimumHeight,
                                            otherEditorHeight)))
                        }

                        Spacer(minLength: 4)

                        Button(secondaryActionLabel(for: question)) {
                            handleOtherSecondaryAction()
                        }
                        .buttonStyle(.plain)
                        .font(.system(
                            size: PlanClarificationCodexPresentation
                                .actionPointSize,
                            weight: .medium))
                        .foregroundStyle(
                            hasExplicitResponse(for: question)
                                ? Color.white
                                : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background {
                            RoundedRectangle(
                                cornerRadius: 9,
                                style: .continuous)
                                .fill(LiquidGlassTokens.ultraworkGradient)
                                .opacity(
                                    hasExplicitResponse(for: question)
                                        ? 0.72
                                        : 0.08)
                        }
                        .chatLiquidSection(
                            cornerRadius: 9,
                            fillOpacity:
                                hasExplicitResponse(for: question) ? 0.12 : 0.05,
                            strokeOpacity:
                                hasExplicitResponse(for: question) ? 0.34 : 0.16,
                            accentOpacity:
                                hasExplicitResponse(for: question) ? 0.30 : 0.10,
                            shadowOpacity:
                                hasExplicitResponse(for: question) ? 0.08 : 0.03)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 32)
                    .background(
                        Color.primary.opacity(
                            isOtherFocused || isOtherHovered ? 0.05 : 0),
                        in: RoundedRectangle(
                            cornerRadius: 16,
                            style: .continuous))
                    .overlay {
                        if isOtherFocused {
                            RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous)
                                .strokeBorder(
                                    LiquidGlassTokens.brandAccent.opacity(0.55),
                                    lineWidth: 1)
                        }
                    }
                    .onHover { isOtherHovered = $0 }
                    .onTapGesture {
                        if question.allowsOtherResponse {
                            focusOther(in: question)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .background(
                Color.secondary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            }
            .background {
                planKeyboardShortcutButtons(for: question)
            }
            .focusable()
            .focused($isCardFocused)
            .onAppear {
                claimInitialCardFocusIfNeeded()
            }
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    navigateQuestionWithKeyboard(by: -1)
                case .right:
                    navigateQuestionWithKeyboard(by: 1)
                case .up:
                    handleVerticalMove(.up)
                case .down:
                    handleVerticalMove(.down)
                default:
                    break
                }
            }
            .onExitCommand {
                cancelAutoAdvance()
                cancelCardFocusRestore()
                dismissed = true
            }
            .accessibilityIdentifier("chat-plan-clarification-card")
        }
    }

    private var isFinalQuestion: Bool {
        questionIndex == questions.count - 1
    }

    private func planKeyboardShortcutButtons(
        for question: PlanQuestionV1
    ) -> some View {
        ZStack {
            ForEach(1...9, id: \.self) { number in
                Button {
                    handleNumericShortcut(number, in: question)
                    restoreCardFocusAfterAction()
                } label: {
                    EmptyView()
                }
                .keyboardShortcut(
                    KeyEquivalent(String(number).first!),
                    modifiers: [])
                .disabled(planShortcutsDisabled)
            }

            Button {
                handleReturnKey()
                restoreCardFocusAfterAction()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(planShortcutsDisabled)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func optionButton(
        _ option: PlanQuestionV1.Option,
        number: Int,
        isFocused: Bool,
        question: PlanQuestionV1
    ) -> some View {
        let isSelected = selections[question.id]?.contains(option.label) == true
        return Button {
            select(option, in: question)
            restoreCardFocusAfterAction()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                optionMarker(
                    number: number,
                    isSelected: isSelected,
                    allowsMultipleSelections:
                        question.allowsMultipleSelections)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.codexDisplayLabel)
                            .font(.system(
                                size: PlanClarificationCodexPresentation
                                    .optionPointSize,
                                weight: .medium))
                        if option.isCodexRecommended {
                            Text("Recommended")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color.secondary.opacity(0.10),
                                    in: Capsule())
                        }
                    }
                        .foregroundStyle(.primary)
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.system(
                                size: PlanClarificationCodexPresentation
                                    .descriptionPointSize))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                if isSelected, !question.allowsMultipleSelections {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .contentShape(
                RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LiquidGlassTokens.ultraworkGradient)
                .opacity(isSelected ? 0.30 : (isFocused ? 0.16 : 0.05))
        }
        .chatLiquidSection(
            cornerRadius: 12,
            fillOpacity: isSelected ? 0.12 : 0.045,
            strokeOpacity: isSelected ? 0.32 : (isFocused ? 0.24 : 0.12),
            accentOpacity: isSelected ? 0.28 : (isFocused ? 0.18 : 0.08),
            shadowOpacity: isSelected || isFocused ? 0.07 : 0.025)
        .accessibilityIdentifier("chat-plan-question-option")
    }

    private var planShortcutsDisabled: Bool {
        let hasCardOwnership = isCardFocused || isRestoringCardFocus
        return !hasCardOwnership
            || !PlanClarificationInteractionPolicy.allowsCardShortcuts(
                isOtherEditorFocused: isOtherFocused)
    }

    private func claimInitialCardFocusIfNeeded() {
        guard PlanClarificationInteractionPolicy.shouldClaimInitialFocus(
            isLatestAssistantMessage: isLatestAssistantMessage,
            alreadyClaimed: initialFocusAlreadyClaimed)
        else { return }
        onInitialFocusClaimed()
        isCardFocused = true
    }

    private func restoreCardFocusAfterAction() {
        focusRestoreGeneration += 1
        let generation = focusRestoreGeneration
        isRestoringCardFocus = true
        isCardFocused = false
        Task { @MainActor in
            await Task.yield()
            guard generation == focusRestoreGeneration,
                  !dismissed,
                  !isOtherFocused
            else {
                if generation == focusRestoreGeneration {
                    isRestoringCardFocus = false
                }
                return
            }
            isCardFocused = true
            isRestoringCardFocus = false
        }
    }

    private func cancelCardFocusRestore() {
        focusRestoreGeneration += 1
        isRestoringCardFocus = false
        restoreCardFocusWhenOtherBlurs = false
    }

    private func prepareToLeaveOtherForCardAction() {
        if isOtherFocused {
            restoreCardFocusWhenOtherBlurs = true
        }
        isOtherFocused = false
    }

    @ViewBuilder
    private func optionMarker(
        number: Int,
        isSelected: Bool,
        allowsMultipleSelections: Bool
    ) -> some View {
        if allowsMultipleSelections {
            ZStack {
                roundMarkerSurface(isActive: isSelected)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(
                width: PlanClarificationCodexPresentation.composerMarkerSize,
                height: PlanClarificationCodexPresentation.composerMarkerSize)
            .padding(.top, 2)
        } else {
            ZStack {
                roundMarkerSurface(isActive: isSelected)
                if isSelected {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 4, height: 4)
                } else {
                    Text("\(number)")
                        .font(.system(
                            size: 9,
                            weight: .medium,
                            design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(
                width:
                    PlanClarificationCodexPresentation.composerMarkerSize,
                height:
                    PlanClarificationCodexPresentation.composerMarkerSize)
        }
    }

    private func otherMarker(
        for question: PlanQuestionV1
    ) -> some View {
        let isActive =
            PlanClarificationInteractionPolicy.otherMarkerIsActive(
                isFocused: isOtherFocused,
                selectedOptionCount:
                    selections[question.id]?.count ?? 0,
                otherText: drafts[question.id] ?? "")
        return ZStack {
            roundMarkerSurface(isActive: isActive)
            Image(systemName: "pencil")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
        }
        .frame(
            width: PlanClarificationCodexPresentation.composerMarkerSize,
            height: PlanClarificationCodexPresentation.composerMarkerSize)
    }

    @ViewBuilder
    private func roundMarkerSurface(isActive: Bool) -> some View {
        if TatwoActivePalette.current.usesGlass {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: Circle())
                    .overlay {
                        Circle()
                            .fill(LiquidGlassTokens.ultraworkGradient)
                            .opacity(isActive ? 0.46 : 0.12)
                    }
                    .overlay {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(
                                            isActive ? 0.42 : 0.28),
                                        Color.white.opacity(0.02),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                            .blendMode(.screen)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(
                                            isActive ? 0.86 : 0.62),
                                        LiquidGlassTokens.accentViolet.opacity(
                                            isActive ? 0.72 : 0.28),
                                        Color.white.opacity(0.36),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing),
                                lineWidth: 0.8)
                    }
                    .shadow(
                        color: LiquidGlassTokens.accentViolet.opacity(
                            isActive ? 0.20 : 0.06),
                        radius: isActive ? 3 : 1.5,
                        y: 1)
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .fill(LiquidGlassTokens.ultraworkGradient)
                            .opacity(isActive ? 0.42 : 0.10)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                Color.white.opacity(isActive ? 0.70 : 0.40),
                                lineWidth: 0.8)
                    }
            }
        } else {
            Circle()
                .fill(
                    isActive
                        ? LiquidGlassTokens.brandAccent
                        : Color.primary.opacity(0.05))
                .overlay {
                    Circle()
                        .strokeBorder(
                            isActive
                                ? LiquidGlassTokens.brandAccent
                                : Color.secondary.opacity(0.22),
                            lineWidth: 1)
                }
        }
    }

    private func hasExplicitResponse(
        for question: PlanQuestionV1
    ) -> Bool {
        let hasOther =
            !(drafts[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMultiSelect =
            question.allowsMultipleSelections
            && !(selections[question.id] ?? []).isEmpty
        return hasOther || hasMultiSelect
    }

    private func secondaryActionLabel(
        for question: PlanQuestionV1
    ) -> String {
        hasExplicitResponse(for: question) ? "Next" : "Skip"
    }

    private func select(
        _ option: PlanQuestionV1.Option,
        in question: PlanQuestionV1,
        source: PlanClarificationSelectionSource = .explicitCommit
    ) {
        let intent = PlanClarificationInteractionPolicy.selectionIntent(
            allowsMultipleSelections: question.allowsMultipleSelections,
            source: source,
            autoAdvancePending: autoAdvancePending)
        guard intent != .ignore else { return }
        prepareToLeaveOtherForCardAction()
        skippedQuestionIDs.remove(question.id)
        explicitlyAnsweredQuestionIDs.insert(question.id)
        if question.allowsMultipleSelections {
            let currentOrder =
                selectionOrders[question.id]
                ?? question.options.compactMap { candidate in
                    selections[question.id]?.contains(candidate.label) == true
                        ? candidate.label
                        : nil
                }
            let updatedOrder =
                PlanClarificationInteractionPolicy.updatedMultiSelectOrder(
                    selectedOptionLabels: currentOrder,
                    toggledOptionLabel: option.label)
            selectionOrders[question.id] = updatedOrder
            selections[question.id] = Set(updatedOrder)
            focusedOptionIndex = updatedOrder.last.flatMap { label in
                question.options.firstIndex { $0.label == label }
            } ?? -1
            focusedOptionIndices[question.id] = focusedOptionIndex
            return
        }
        if let index = question.options.firstIndex(of: option) {
            focusedOptionIndex = index
            focusedOptionIndices[question.id] = index
        }
        selections[question.id] = [option.label]
        guard intent == .selectAndAutoAdvance else { return }
        autoAdvancePending = true
        autoAdvanceGeneration += 1
        let generation = autoAdvanceGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard generation == autoAdvanceGeneration,
                  autoAdvancePending,
                  selections[question.id] == [option.label],
                  !dismissed
            else { return }
            advance(skipping: false)
        }
    }

    private func draftBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { drafts[questionID, default: ""] },
            set: { value in
                drafts[questionID] = value
                if !value.isEmpty {
                    explicitlyAnsweredQuestionIDs.insert(questionID)
                    if let question = questions.first(where: {
                        $0.id == questionID
                    }),
                       !question.allowsMultipleSelections
                    {
                        selections[questionID] = []
                    }
                    skippedQuestionIDs.remove(questionID)
                    cancelAutoAdvance()
                }
            })
    }

    private func navigateQuestion(by offset: Int) {
        guard !questions.isEmpty else { return }
        let destination = min(
            max(questionIndex + offset, 0),
            questions.count - 1)
        guard destination != questionIndex else { return }
        cancelAutoAdvance()
        if let question = currentQuestion {
            focusedOptionIndices[question.id] = focusedOptionIndex
        }
        questionIndex = destination
        let destinationQuestion = questions[destination]
        focusedOptionIndex =
            focusedOptionIndices[destinationQuestion.id]
            ?? PlanClarificationInteractionPolicy.initialFocusedOptionIndex(
                allowsMultipleSelections:
                    destinationQuestion.allowsMultipleSelections,
                optionCount: destinationQuestion.options.count)
        isOtherFocused = false
    }

    private func navigateQuestionAndRestoreFocus(by offset: Int) {
        prepareToLeaveOtherForCardAction()
        navigateQuestion(by: offset)
        restoreCardFocusAfterAction()
    }

    private func navigateQuestionWithKeyboard(by offset: Int) {
        guard PlanClarificationInteractionPolicy
            .allowsKeyboardQuestionNavigation(
                autoAdvancePending: autoAdvancePending)
        else { return }
        navigateQuestion(by: offset)
    }

    private func handleVerticalMove(
        _ direction: PlanClarificationVerticalDirection
    ) {
        guard let question = currentQuestion else { return }
        switch PlanClarificationInteractionPolicy.verticalMove(
            from: focusedOptionIndex,
            direction: direction,
            optionCount: question.options.count,
            allowsOtherResponse: question.allowsOtherResponse)
        {
        case .stay:
            break
        case .selectOption(let index):
            guard question.options.indices.contains(index) else { return }
            select(
                question.options[index],
                in: question,
                source: .verticalNavigation)
        case .focusOther:
            focusOther(in: question)
        }
    }

    private func handleOtherArrowUp() {
        prepareToLeaveOtherForCardAction()
        handleVerticalMove(.up)
        restoreCardFocusAfterAction()
    }

    private func handleNumericShortcut(
        _ number: Int,
        in question: PlanQuestionV1
    ) {
        guard !isOtherFocused else { return }
        switch PlanClarificationInteractionPolicy.numericShortcut(
            number: number,
            optionCount: question.options.count,
            allowsOtherResponse: question.allowsOtherResponse,
            autoAdvancePending: autoAdvancePending)
        {
        case .ignore:
            break
        case .selectOption(let index):
            guard question.options.indices.contains(index) else { return }
            select(question.options[index], in: question)
        case .focusOther:
            let updatedOrder =
                PlanClarificationInteractionPolicy
                    .selectionOrderAfterNumericOther(
                        allowsMultipleSelections:
                            question.allowsMultipleSelections,
                        selectedOptionLabels:
                            selectionOrders[question.id] ?? [])
            if question.allowsMultipleSelections {
                selectionOrders[question.id] = updatedOrder
                selections[question.id] = Set(updatedOrder)
            }
            focusOther(in: question)
        }
    }

    private func focusOther(in question: PlanQuestionV1) {
        guard question.allowsOtherResponse else { return }
        cancelCardFocusRestore()
        cancelAutoAdvance()
        focusedOptionIndex = question.options.count
        focusedOptionIndices[question.id] = question.options.count
        isOtherFocused = true
        skippedQuestionIDs.remove(question.id)
        if !question.allowsMultipleSelections {
            selections[question.id] = []
        }
    }

    private func handleSkip() {
        guard let question = currentQuestion else { return }
        let intent = PlanClarificationInteractionPolicy.skipIntent(
            allowsMultipleSelections: question.allowsMultipleSelections,
            selectedOptionCount: selections[question.id]?.count ?? 0,
            otherText: drafts[question.id, default: ""])
        advance(skipping: intent == .skip)
    }

    private func handleOtherSecondaryAction() {
        prepareToLeaveOtherForCardAction()
        handleSkip()
        guard !dismissed else { return }
        restoreCardFocusAfterAction()
    }

    private func handleOtherReturnKey() {
        prepareToLeaveOtherForCardAction()
        handleReturnKey()
        guard !dismissed else { return }
        restoreCardFocusAfterAction()
    }

    private func handleReturnKey() {
        guard let question = currentQuestion else { return }
        let selectedOptionIndex = question.options.firstIndex {
            selections[question.id]?.contains($0.label) == true
        }
        switch PlanClarificationInteractionPolicy.returnIntent(
            allowsMultipleSelections: question.allowsMultipleSelections,
            selectedOptionIndex: selectedOptionIndex)
        {
        case .reselectOption(let index):
            guard question.options.indices.contains(index) else { return }
            select(question.options[index], in: question)
        case .advance:
            handleSkip()
        }
    }

    private func hasAnswer(for question: PlanQuestionV1) -> Bool {
        !(selections[question.id] ?? []).isEmpty
            || !(drafts[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func advance(skipping: Bool) {
        guard let question = currentQuestion else { return }
        cancelAutoAdvance()
        if skipping {
            skippedQuestionIDs.insert(question.id)
            selections[question.id] = []
            selectionOrders[question.id] = []
            drafts[question.id] = ""
        } else {
            guard hasAnswer(for: question) else { return }
            skippedQuestionIDs.remove(question.id)
        }
        if isFinalQuestion {
            submit()
        } else {
            focusedOptionIndices[question.id] = focusedOptionIndex
            questionIndex += 1
            let destinationQuestion = questions[questionIndex]
            focusedOptionIndex =
                focusedOptionIndices[destinationQuestion.id]
                ?? PlanClarificationInteractionPolicy
                    .initialFocusedOptionIndex(
                        allowsMultipleSelections:
                            destinationQuestion.allowsMultipleSelections,
                        optionCount: destinationQuestion.options.count)
            restoreCardFocusAfterAction()
        }
    }

    private func cancelAutoAdvance() {
        autoAdvanceGeneration += 1
        autoAdvancePending = false
    }

    private func submit() {
        let answers = questions.map { question in
            let explicitlySkipped =
                skippedQuestionIDs.contains(question.id)
            let wasExplicitlyAnswered = explicitlyAnsweredQuestionIDs.contains(question.id)
            let selectedOptions = question.options.filter {
                selections[question.id]?.contains($0.label) == true
            }
            let otherText = drafts[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAnswer =
                !selectedOptions.isEmpty || otherText?.isEmpty == false
            let shouldSkip = explicitlySkipped || !wasExplicitlyAnswered
                || !hasAnswer
            return PlanQuestionAnswerV1(
                questionID: question.id,
                selectedOptions: shouldSkip ? [] : selectedOptions,
                otherText: shouldSkip ? nil : otherText,
                skipped: shouldSkip)
        }
        cancelCardFocusRestore()
        dismissed = true
        NotificationCenter.default.post(
            name: .tatwoChatAnswerPlanQuestion,
            object: PlanQuestionResponseBatchV1(answers: answers))
    }
}
