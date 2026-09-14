import SwiftUI

struct SpaceLiveSetupView: View {
    @ObservedObject private var controller = SpaceWorkspaceController.shared
    var opensSettings = false
    var onOpenBuilder: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if let error = controller.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
            }
            if let state = controller.state {
                SpaceSetupPreviewView(preview: state, opensSettings: opensSettings,
                                      onOpenBuilder: onOpenBuilder)
            } else {
                Text(controller.error == nil ? "正在讀取 work space…" : "Work Space 資料未就緒")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SpaceLiveConversationView: View {
    @ObservedObject var model: ChatPageModel
    @ObservedObject var domain: SpaceSetupPreviewState.Domain
    let item: SpaceSetupPreviewState.WorkInterface
    @State private var draft = ""
    @State private var textHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
    @State private var failure: String?
    @State private var requestID = UUID()
    @State private var sending = false
    @State private var recoveryRequired = false
    private var interfaceID: UUID? { UUID(uuidString: item.id) }
    private var conversationID: UUID? { UUID(uuidString: item.conversationID) }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(item.name) · \(item.bot.name)").font(.headline)
                    if let interfaceID {
                        ForEach(model.spaceInterfaceTranscript(spaceID: domain.id, interfaceID: interfaceID)) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == .user ? "你" : item.bot.name)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: ChatUILayout.chatColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            VStack(spacing: 8) {
                ChatComposerTextView(text: $draft, contentHeight: $textHeight, isFocused: false,
                    placeholder: "繼續搭建這個自訂 work space", isMonospaced: false,
                    minimumHeight: TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight,
                    maximumHeight: TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight,
                    onSubmit: send, onFocusChange: { _ in }, accessibilityTextLabel: "自訂 work space搭建對話")
                    .frame(height: textHeight)
                HStack {
                    Text(item.bot.name).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.live?.isRunning(conversationID) == true {
                        ProgressView().controlSize(.small)
                    } else {
                        ChatComposerSendButton(enabled: !sending && !recoveryRequired
                            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: send)
                    }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
            .padding(16)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
            .frame(maxWidth: ChatUILayout.chatColumnMaxWidth)
            .padding(.horizontal, 24).padding(.bottom, 18)
        }
        .task(id: item.id) {
            draft = model.botLibraryForBridge?.snapshot.spaceWorkspace.domains[domain.id]?
                .conversationDrafts?[item.id] ?? ""
            let pending = model.botLibraryForBridge?.snapshot.spaceWorkspace.domains[domain.id]?.followupRequests?[item.id]
            recoveryRequired = pending?.status == .dispatching || pending?.status == .recoveryRequired
            if recoveryRequired {
                failure = "上次送出狀態待確認，已保留草稿並禁止重送。"
            }
        }
        .onChange(of: draft) { saveDraft($0) }
    }

    private func saveDraft(_ text: String) {
        SpaceWorkspaceController.shared.saveConversationDraft(spaceID: domain.id, interfaceID: item.id, text: text)
    }

    private func send() {
        guard let interfaceID, !sending, !recoveryRequired,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let spaceID = domain.id, text = draft, attempt = requestID
        sending = true
        Task {
            defer { sending = false }
            await SpaceWorkspaceController.shared.flushWrites()
            do {
                try await model.sendSpaceFollowup(spaceID: spaceID, interfaceID: interfaceID,
                                                  requestID: attempt, text: text)
                if draft == text { draft = "" }
                requestID = UUID()
                failure = nil
            } catch {
                let status = model.botLibraryForBridge?.snapshot.spaceWorkspace.domains[spaceID]?
                    .followupRequests?[interfaceID.uuidString]?.status
                recoveryRequired = status == .dispatching || status == .recoveryRequired
                failure = recoveryRequired ? "送出狀態待確認，已禁止重送：\(error)" : "未送出，草稿已保留：\(error)"
            }
        }
    }
}

/// Builder presentation is independent of the active work space; opening it never selects Bot.
struct SpaceBuilderPresentation: ViewModifier {
    @ObservedObject private var controller = SpaceWorkspaceController.shared
    @ObservedObject private var preview = SpaceSetupPreviewState.shared
    private var activeState: SpaceSetupPreviewState? {
        SpaceSetupPreviewState.isEnabled ? preview : controller.state
    }
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { activeState?.selectedDomain.presentsBuilder ?? false },
            set: { activeState?.selectedDomain.presentsBuilder = $0 }
        )) {
            if let state = activeState {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("關閉") { state.selectedDomain.presentsBuilder = false }
                    }.padding(12)
                    SpaceSetupPreviewView(preview: state)
                }
                .frame(minWidth: 640, minHeight: 520)
            }
        }
    }
}
