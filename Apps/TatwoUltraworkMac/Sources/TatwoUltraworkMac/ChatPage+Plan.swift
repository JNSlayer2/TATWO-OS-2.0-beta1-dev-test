import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

enum ChatTranscriptScrollDestination: Equatable {
    case none
    case bottom
    case itemTop(String)

    static func resolve(
        latestAssistantMessageID: String?,
        hasPlanArtifact: Bool,
        isPlanWriting: Bool,
        latestAssistantHasPlanQuestions: Bool,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> Self {
        guard contentHeight > viewportHeight + 1 else {
            return .none
        }
        if isPlanWriting {
            return .itemTop("tatwo-plan-writing-summary")
        }
        if hasPlanArtifact || latestAssistantHasPlanQuestions,
           let latestAssistantMessageID
        {
            return .itemTop("message:\(latestAssistantMessageID)")
        }
        return .bottom
    }
}

enum ChatPlanArtifactTranscriptProjection {
    enum CompletedArtifactPlacement: Equatable {
        case none
        case attachedToSourceAssistant
        case standalone
    }

    struct Placement: Equatable {
        let completedArtifact: CompletedArtifactPlacement
        let includesWritingRow: Bool
    }

    static func placement(
        hasArtifact: Bool,
        sourceAssistantMessageID: String?,
        isPlanWriting: Bool
    ) -> Placement {
        let completedArtifact: CompletedArtifactPlacement
        if !hasArtifact {
            completedArtifact = .none
        } else if sourceAssistantMessageID == nil {
            completedArtifact = .standalone
        } else {
            completedArtifact = .attachedToSourceAssistant
        }

        return Placement(
            completedArtifact: completedArtifact,
            includesWritingRow: isPlanWriting)
    }
}

enum PlanDownloadPolicy {
    static let promptForLocationDefaultsKey =
        "tatwo.downloads.promptForLocation"
    static let downloadDirectoryDefaultsKey =
        "tatwo.downloads.directory"

    static func shouldPromptForLocation(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: promptForLocationDefaultsKey)
    }

    static func downloadDirectory(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        if let configuredPath = defaults.string(
            forKey: downloadDirectoryDefaultsKey),
           !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }
        return fileManager.urls(
            for: .downloadsDirectory,
            in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
    }

    static func availableDestination(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let original = directory.appendingPathComponent("PLAN.md")
        guard fileManager.fileExists(atPath: original.path) else {
            return original
        }

        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent(
                "PLAN \(suffix).md")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

private struct PlanWritingAnimatedText: View {
    @State private var isDimmed = false

    var body: some View {
        Text("Writing plan")
            .opacity(isDimmed ? 0.52 : 1)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isDimmed)
            .onAppear {
                isDimmed = true
            }
    }
}

private extension View {
    /// Compact, equal-size Plan toolbar target.
    func planSummaryActionStyle() -> some View {
        font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

/// Codex-style Plan transcript item. Model-produced plans attach to their
/// assistant turn; deterministic local plans render as a standalone row.
/// While a Plan turn is active the row reads “Writing plan”.
struct PlanTranscriptSummaryView: View {
    let artifact: TatwoPlanArtifactV1?
    let isWriting: Bool
    @Binding var isSidePanelPresented: Bool

    @State private var copied = false

    private static let collapsedContentHeight: CGFloat = 160
    private static let collapsedCardHeight: CGFloat = 200

    private var markdown: String {
        artifact?.markdownExport() ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 14))
                Group {
                    if isWriting {
                        PlanWritingAnimatedText()
                    } else {
                        Text("Plan")
                    }
                }
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if artifact != nil {
                    if isSidePanelPresented {
                        Button {
                            isSidePanelPresented = false
                        } label: {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .help("Close plan side panel")
                        .accessibilityLabel("Close plan side panel")
                        .accessibilityIdentifier("plan-summary-side-panel")
                    } else {
                        planHeaderActions
                    }
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 40)

            if let artifact, !isSidePanelPresented {
                planBody(artifact)
            }
        }
        .frame(
            height: artifact != nil
                ? (isSidePanelPresented
                    ? 40
                    : Self.collapsedCardHeight)
                : nil,
            alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private var planHeaderActions: some View {
        HStack(spacing: 4) {
            Button {
                downloadPlan()
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help("Download plan")
            .accessibilityLabel("Download plan")
            .accessibilityIdentifier("plan-summary-download")

            Button {
                copyPlan()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help(copied ? "Copied" : "Copy markdown")
            .accessibilityIdentifier("plan-summary-copy")

            Button {
                openPlanSidePanel()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help("Open plan in side panel")
            .accessibilityLabel("Open plan in side panel")
            .accessibilityIdentifier("plan-summary-side-panel")
        }
    }

    private func planBody(
        _ artifact: TatwoPlanArtifactV1
    ) -> some View {
        ZStack(alignment: .bottom) {
            planMarkdownText
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(
                    height: Self.collapsedContentHeight,
                    alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            // Codex: black calc(100% - 4rem) on a 160pt preview.
                            .init(color: .black, location: 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom)
                }

            Button {
                openPlanSidePanel()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open plan in side panel")
            .accessibilityIdentifier("plan-summary-preview-open")
        }
        .frame(
            height: Self.collapsedContentHeight,
            alignment: .top)
    }

    private func openPlanSidePanel() {
        if !isSidePanelPresented {
            isSidePanelPresented = true
        }
    }

    private var planMarkdownText: some View {
        PlanTranscriptMarkdownView(markdown: markdown)
    }

    private func copyPlan() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            copied = false
        }
    }

    private func downloadPlan() {
        if PlanDownloadPolicy.shouldPromptForLocation() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "PLAN.md"
            panel.allowedContentTypes = [
                UTType(filenameExtension: "md") ?? .plainText
            ]
            guard TatwoModalPanelGate.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let fileManager = FileManager.default
        let directory = PlanDownloadPolicy.downloadDirectory(
            fileManager: fileManager)
        let destination = PlanDownloadPolicy.availableDestination(
            in: directory,
            fileManager: fileManager)
        try? markdown.write(
            to: destination,
            atomically: true,
            encoding: .utf8)
    }
}

private struct PlanTranscriptMarkdownView: View {
    let markdown: String

    var body: some View {
        ChatAssistantTranscriptBlockView(
            document: TatwoAssistantTranscriptPresentation.document(
                markdown: markdown),
            copyAllText: markdown,
            tracksAvailableWidth: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

struct PlanTranscriptInspectorView: View {
    let artifact: TatwoPlanArtifactV1?
    @Binding var isPresented: Bool
    let selection: TatwoPlanArtifactV1.PlanFlowSelectionV1?
    let localActionPresentation:
        ChatPlanWorkOSLocalActionPresentation
    let editableText: String?
    let onSelectionChange:
        (TatwoPlanArtifactV1.PlanFlowSelectionV1) -> Void
    let onSaveEditedText: (String) -> Void
    let ultraworkPanel: AnyView
    let ultraworkPrimaryModelID: String
    let ultraworkSecondaryModelID: String?
    let ultraworkAuxiliaryCount: Int
    let onDismissUltrawork: () -> Void
    let onExecute: () -> Void

    @State private var isCollapsed = false
    @State private var copied = false
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var showsUltraworkCanvas = false

    private static let collapsedHeight: CGFloat = 320

    private var markdown: String {
        artifact?.markdownExport() ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Close") {
                    onDismissUltrawork()
                    isPresented = false
                }
                .buttonStyle(.plain)
            }
            if let artifact {
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            inspectorHeader
                            inspectorBody(markdown: artifact.markdownExport())
                            if showsUltraworkCanvas {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text("Ultrawork")
                                            .font(.system(
                                                size: 13,
                                                weight: .semibold))
                                        Spacer(minLength: 8)
                                        Button("返回接續選項") {
                                            onDismissUltrawork()
                                            showsUltraworkCanvas = false
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(
                                            size: 11,
                                            weight: .medium))
                                    }
                                    .padding(.horizontal, 2)

                                    ultraworkPanel
                                        .frame(
                                            maxWidth: .infinity,
                                            alignment: .topLeading)
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            } else {
                                PlanExecutionHandoffView(
                                    selection: selection,
                                    localActionPresentation:
                                        localActionPresentation,
                                    ultraworkPrimaryModelID:
                                        ultraworkPrimaryModelID,
                                    ultraworkSecondaryModelID:
                                        ultraworkSecondaryModelID,
                                    ultraworkAuxiliaryCount:
                                        ultraworkAuxiliaryCount,
                                    onSelectionChange: onSelectionChange,
                                    onOpenUltrawork: {
                                        withAnimation(.spring(
                                            response: 0.22,
                                            dampingFraction: 0.86))
                                        {
                                            showsUltraworkCanvas = true
                                        }
                                    },
                                    onExecute: onExecute)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                            }
                        }
                        .background(
                            Color.secondary.opacity(0.055),
                            in: RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous))
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous)
                                .strokeBorder(
                                    Color.secondary.opacity(0.16),
                                    lineWidth: 1)
                        }
                        .frame(
                            width: viewport.size.width,
                            alignment: .leading)
                    }
                }
            } else {
                Text("No plan is available.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .inspectorColumnWidth(min: 320, ideal: 420, max: 560)
    }

    private var inspectorHeader: some View {
        HStack(spacing: 4) {
            Text("Plan")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            Button {
                downloadPlan()
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help("Download plan")
            .accessibilityLabel("Download plan")

            Button {
                copyPlan()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help(copied ? "Copied" : "Copy markdown")

            Button {
                if isEditing {
                    onSaveEditedText(editedText)
                    isEditing = false
                } else {
                    editedText = editableText ?? markdown
                    isEditing = true
                    isCollapsed = false
                }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help(isEditing ? "Finish editing plan" : "Edit plan")
            .accessibilityLabel(
                isEditing ? "Finish editing plan" : "Edit plan")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees(isCollapsed ? 180 : 0))
            }
            .buttonStyle(.plain)
            .planSummaryActionStyle()
            .help(isCollapsed ? "Expand" : "Collapse")
            .accessibilityLabel(
                isCollapsed
                    ? "Expand plan summary"
                    : "Collapse plan summary")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func inspectorBody(markdown: String) -> some View {
        ZStack(alignment: .bottom) {
            if isEditing {
                TextEditor(text: $editedText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.collapsedHeight,
                        alignment: .topLeading)
                    .accessibilityIdentifier("plan-inspector-editor")
            } else {
                PlanTranscriptMarkdownView(markdown: markdown)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(
                        height: isCollapsed ? Self.collapsedHeight : nil,
                        alignment: .top)
                    .clipped()
            }

            if isCollapsed && !isEditing {
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(nsColor: .windowBackgroundColor).opacity(0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
                    .frame(height: 160)
                    .allowsHitTesting(false)

                Button("Expand plan") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 12)
            }
        }
    }

    private func copyPlan() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            copied = false
        }
    }

    private func downloadPlan() {
        let fileManager = FileManager.default
        let directory = PlanDownloadPolicy.downloadDirectory(
            fileManager: fileManager)
        let destination = PlanDownloadPolicy.availableDestination(
            in: directory,
            fileManager: fileManager)
        try? markdown.write(
            to: destination,
            atomically: true,
            encoding: .utf8)
    }
}

private struct PlanExecutionHandoffView: View {
    private typealias Destination =
        TatwoPlanArtifactV1.PlanFlowSelectionV1.Destination
    private typealias Collaboration =
        TatwoPlanArtifactV1.PlanFlowSelectionV1.Collaboration

    @State private var destination: Destination?
    @State private var collaboration: Collaboration?

    /// Ultrawork 角色設定的真實來源是這個 session 的協作設定，不是這張卡片
    /// 自己的狀態。卡片只把它投影進 plan flow selection，讓「主導 terra 已
    /// 設定」和「執行閘門」看到同一份資料。
    let ultraworkPrimaryModelID: String
    let ultraworkSecondaryModelID: String?
    let ultraworkAuxiliaryCount: Int
    let localActionPresentation:
        ChatPlanWorkOSLocalActionPresentation
    let onSelectionChange:
        (TatwoPlanArtifactV1.PlanFlowSelectionV1) -> Void
    let onOpenUltrawork: () -> Void
    let onExecute: () -> Void

    init(
        selection: TatwoPlanArtifactV1.PlanFlowSelectionV1?,
        localActionPresentation:
            ChatPlanWorkOSLocalActionPresentation,
        ultraworkPrimaryModelID: String,
        ultraworkSecondaryModelID: String?,
        ultraworkAuxiliaryCount: Int,
        onSelectionChange:
            @escaping (TatwoPlanArtifactV1.PlanFlowSelectionV1) -> Void,
        onOpenUltrawork: @escaping () -> Void,
        onExecute: @escaping () -> Void
    ) {
        _destination = State(initialValue: selection?.destination)
        _collaboration = State(initialValue: selection?.collaboration)
        self.localActionPresentation = localActionPresentation
        self.ultraworkPrimaryModelID = ultraworkPrimaryModelID
        self.ultraworkSecondaryModelID = ultraworkSecondaryModelID
        self.ultraworkAuxiliaryCount = ultraworkAuxiliaryCount
        self.onSelectionChange = onSelectionChange
        self.onOpenUltrawork = onOpenUltrawork
        self.onExecute = onExecute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("接續執行")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                destinationButton(
                    title: "/goal",
                    subtitle: "建立目標",
                    value: .goal,
                    accessibilityID: "plan-execution-goal")
                destinationButton(
                    title: "/plg",
                    subtitle: "進入流程",
                    value: .plg,
                    accessibilityID: "plan-execution-plg")
            }

            HStack(spacing: 8) {
                collaborationButton(
                    title: "單模型",
                    value: .singleModel,
                    accessibilityID: "plan-execution-single-model")
                collaborationButton(
                    title: "Ultrawork",
                    value: .multiModel,
                    accessibilityID: "plan-execution-ultrawork")
            }

            Text(currentSelection.selectionSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("plan-execution-selection")

            if let blocker = currentSelection.executionBlocker {
                Text(blocker)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("plan-execution-run-guard")
            }

            if localActionPresentation.phase != .idle,
               !localActionPresentation.message.isEmpty
            {
                Text(localActionPresentation.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        localActionPresentation.phase == .failed
                            ? Color.red
                            : Color.secondary)
                    .accessibilityIdentifier(
                        "plan-confirm-work-os-status")
            }

            Button {
                persistSelection()
                guard currentSelection.executionBlocker == nil,
                      !localActionPresentation.isInFlight,
                      localActionPresentation.phase != .succeeded
                else { return }
                onExecute()
            } label: {
                Label(
                    localActionPresentation.phase == .failed
                        ? "重試送交 Work OS"
                        : "確認計畫／送交 Work OS",
                    systemImage:
                        localActionPresentation.isInFlight
                            ? "hourglass"
                            : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chatGlassChip(isSelected: confirmActionIsEnabled)
            .disabled(!confirmActionIsEnabled)
            .opacity(confirmActionIsEnabled ? 1 : 0.45)
            .accessibilityIdentifier("plan-execution-run")
        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.13), lineWidth: 1)
        }
    }

    private var confirmActionIsEnabled: Bool {
        currentSelection.executionBlocker == nil
            && !localActionPresentation.isInFlight
            && localActionPresentation.phase != .succeeded
    }

    private func destinationButton(
        title: String,
        subtitle: String,
        value: Destination,
        accessibilityID: String
    ) -> some View {
        Button {
            destination = value
            persistSelection()
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(
                        size: 12,
                        weight: .semibold,
                        design: .monospaced))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatGlassChip(isSelected: destination == value)
        .overlay {
            if destination == value {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
            }
        }
        .accessibilityAddTraits(destination == value ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
    }

    private func collaborationButton(
        title: String,
        value: Collaboration,
        accessibilityID: String
    ) -> some View {
        Button {
            collaboration = value
            persistSelection()
            if value == .multiModel {
                onOpenUltrawork()
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatGlassChip(isSelected: collaboration == value)
        .overlay {
            if collaboration == value {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
            }
        }
        .accessibilityAddTraits(collaboration == value ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
    }

    private var currentSelection: TatwoPlanArtifactV1.PlanFlowSelectionV1 {
        let isUltrawork = collaboration == .multiModel
        return TatwoPlanArtifactV1.PlanFlowSelectionV1(
            destination: destination,
            collaboration: collaboration,
            modelAssignment: collaboration.map {
                $0 == .singleModel ? .single : .primarySecondary
            },
            primaryModelID: isUltrawork ? ultraworkPrimaryModelID : nil,
            secondaryModelID: isUltrawork && ultraworkAuxiliaryCount > 0
                ? ultraworkSecondaryModelID
                : nil,
            auxiliaryModelCount: isUltrawork ? ultraworkAuxiliaryCount : nil)
    }

    private func persistSelection() {
        onSelectionChange(currentSelection)
    }
}
