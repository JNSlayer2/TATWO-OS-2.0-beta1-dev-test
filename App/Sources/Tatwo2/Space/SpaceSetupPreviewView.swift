import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Content-only preview, hosted by the existing Bot shell or Settings content slot.
/// Navigation callback only dismisses Settings; there is no engine/store callback.
struct SpaceSetupPreviewView: View {
    @ObservedObject var preview = SpaceSetupPreviewState.shared
    var opensSettings = false
    var onOpenBuilder: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if !preview.selectedDomain.isProduction {
            HStack {
                Text("Space・UI 預覽").font(.caption.weight(.semibold))
                Spacer()
                Text("示例資料，不會建立 Bot 或送出訊息")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            }
            SpaceSetupDomainView(domain: preview.selectedDomain, onOpenBuilder: onOpenBuilder)
                .id(preview.selectedDomainID)
        }
        .onAppear {
            if opensSettings { preview.selectedDomain.screen = .settings }
        }
    }
}

private struct SpaceSetupDomainView: View {
    @ObservedObject var domain: SpaceSetupPreviewState.Domain
    var onOpenBuilder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(domain.name).font(.headline)
                Spacer()
                if case .settings = domain.screen {
                    EmptyView()
                } else {
                    Button("設定") { domain.screen = .settings }
                        .accessibilityIdentifier("space-preview-settings")
                }
            }
            .buttonStyle(.plain)
            .padding(14)
            if !domain.interfaces.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(domain.interfaces) { item in
                            Button(item.name) { domain.selectInterface(item.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            switch domain.screen {
            case .settings: settings
            case .builder: SpaceSetupBuilderView(domain: domain)
            case .interface, .conversation:
                if domain.isProduction, let item = domain.selectedInterface,
                   let model = CLISessionsTermination.model {
                    SpaceLiveConversationView(model: model, domain: domain, item: item)
                        .id(domain.id + ":" + item.id)
                } else if case .interface = domain.screen { interfacePreview }
                else { conversationPreview }
            case .tab(let tab):
                VStack(spacing: 12) {
                    Label(tab.rawValue, systemImage: tab.symbol).font(.title2)
                    Text("只預覽分頁位置；未啟動 \(tab.rawValue) 的程序或服務。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Space").font(.title2.weight(.semibold))
                Text("只管理「\(domain.name)」的分頁與工作介面。")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(domain.tabs) { tab in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Button { domain.toggle(tab) } label: {
                                Label(tab.rawValue, systemImage: domain.isRequestedEnabled(tab) ? "checkmark.square.fill" : "square")
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(domain.pendingDisabledTabs.contains(tab)
                                ? "未勾選，等待任務結束後停用"
                                : (domain.isRequestedEnabled(tab) ? "已勾選" : "未勾選"))
                            if domain.pendingDisabledTabs.contains(tab) {
                                Text("待停用・任務仍執行中")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { domain.moveTab(tab, offset: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .accessibilityLabel("向上移動 \(tab.rawValue)")
                            .disabled(domain.tabs.first == tab)
                            Button { domain.moveTab(tab, offset: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel("向下移動 \(tab.rawValue)")
                            .disabled(domain.tabs.last == tab)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                        .onDrag {
                            NSItemProvider(object: "\(domain.id):\(tab.rawValue)" as NSString)
                        }
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            guard let provider = providers.first,
                                  provider.canLoadObject(ofClass: NSString.self) else { return false }
                            // Capture the owner before the asynchronous load: a domain switch
                            // must never redirect a drop into the newly selected Space.
                            let owner = domain
                            _ = provider.loadObject(ofClass: NSString.self) { object, error in
                                guard error == nil, let payload = object as? String else { return }
                                DispatchQueue.main.async {
                                    guard let source = SpaceSetupPreviewState.Tab.allCases.first(where: {
                                        payload == "\(owner.id):\($0.rawValue)"
                                    }) else { return }
                                    owner.moveTab(source, before: tab)
                                }
                            }
                            return true
                        }
                        Divider()
                    }
                }
                Text(domain.isProduction
                     ? "未勾選的分頁不顯示、不隨 OS 啟動；執行中的工作保留至結束。"
                     : "未勾選的分頁將不顯示、不隨 OS 啟動；有任務執行時，須等任務結束才停用。此預覽不會改變實際服務。")
                    .font(.caption).foregroundStyle(.secondary)
                if !domain.isProduction {
                DisclosureGroup("任務狀態預覽（不執行真實任務）") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(domain.tabs) { tab in
                            HStack {
                                Text("\(tab.rawValue)：\(domain.runningTabs.contains(tab) ? "示例任務執行中" : "閒置")")
                                Spacer()
                                Button(domain.runningTabs.contains(tab) ? "預覽任務結束" : "預覽任務執行中") {
                                    domain.setPreviewTaskRunning(!domain.runningTabs.contains(tab), for: tab)
                                }
                                .disabled(!domain.enabledTabs.contains(tab))
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                }
                HStack {
                    Text("工作介面").font(.headline)
                    Spacer()
                    Button("+add") {
                        domain.openBuilder()
                        onOpenBuilder()
                    }
                        .accessibilityIdentifier("space-preview-settings-add")
                }
                if domain.interfaces.isEmpty {
                    Text("尚未建立工作介面").foregroundStyle(.secondary)
                }
                ForEach(domain.interfaces) { item in
                    Button { domain.selectInterface(item.id) } label: {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(item.bot.name).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
        }
    }

    private var interfacePreview: some View {
        VStack(spacing: 18) {
            Spacer()
            if let item = domain.selectedInterface {
                Image(systemName: "rectangle.on.rectangle").font(.largeTitle)
                Text(item.name).font(.title2.weight(.semibold))
                Text("工作介面呈現在 \(item.bot.name) 的對話之上。")
                    .foregroundStyle(.secondary)
                Text("這是位置與動線預覽，尚未搭建業務功能。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("開啟搭建對話") { domain.selectInterface(item.id, conversation: true) }
            } else {
                Button("新增工作介面") { domain.openBuilder() }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bot").font(.title2.weight(.semibold))
                ForEach(domain.bots) { bot in
                    Text(bot.name).font(.headline)
                    ForEach(domain.interfaces.filter { $0.bot.id == bot.id }) { item in
                        Button("\(item.name)・搭建對話") {
                            domain.selectInterface(item.id, conversation: true)
                        }
                    }
                }
                if let item = domain.selectedInterface {
                    Divider()
                    Text("\(item.bot.name) · \(item.name)").font(.headline)
                    Text(item.specification)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("space-preview-conversation-\(item.conversationID)")
                    Text("僅呈現剛才的輸入；未送出，沒有模擬 AI 回覆。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("返回工作介面") { domain.screen = .interface }
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SpaceSetupBuilderView: View {
    @ObservedObject var domain: SpaceSetupPreviewState.Domain
    @State private var focused = false
    @State private var textHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
    @State private var copyMessage = "複製規格"
    @State private var composerWidth: CGFloat = ChatUILayout.chatColumnMaxWidth

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("工作介面搭建規格").font(.headline)
                        Spacer()
                        Button(copyMessage) { copySpecification() }
                            .accessibilityIdentifier("space-preview-copy-specification")
                    }
                    Text(SpaceSetupPreviewState.specificationPrompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: ChatUILayout.chatColumnMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
            composer
        }
    }

    private var composer: some View {
        let minHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
        let maxHeight = TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("搭建 Bot", selection: $domain.chosenBotID) {
                    Text("建立專屬 Bot").tag("")
                    ForEach(domain.bots) { bot in Text(bot.name).tag(bot.id) }
                }
                .accessibilityLabel("搭建 Bot：建立專屬 Bot 或選目前 Space 已有 Bot")
                .frame(maxWidth: 280)
                Spacer(minLength: 0)
                Button("取消") { domain.cancelBuilder() }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 0) {
                ChatComposerTextView(
                    text: $domain.draft, contentHeight: $textHeight,
                    isFocused: focused, placeholder: "描述你希望如何搭建這個工作介面",
                    isMonospaced: false, minimumHeight: minHeight, maximumHeight: maxHeight,
                    onSubmit: { domain.previewResult() },
                    onFocusChange: { focused = $0 },
                    accessibilityTextLabel: domain.isProduction ? "Space 搭建需求" : "Space 搭建需求（UI 預覽）")
                    .frame(height: min(maxHeight, max(minHeight, textHeight)))
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
                    .padding(.bottom, 8)
                SpaceSetupComposerToolbar(domain: domain, compact: composerWidth < 720)
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
            }
            .frame(minHeight: TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { composerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { composerWidth = $0 }
                }
            }
            Text(domain.validationMessage ?? (domain.isProduction
                ? "所屬 Space：\(domain.name)" : "所屬 Space：\(domain.name) · 未接入引擎，所有操作僅供 UI 預覽"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: ChatUILayout.chatColumnMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private func copySpecification() {
        NSPasteboard.general.clearContents()
        copyMessage = NSPasteboard.general.setString(
            SpaceSetupPreviewState.specificationPrompt, forType: .string) ? "已複製" : "複製失敗，請重試"
    }
}
