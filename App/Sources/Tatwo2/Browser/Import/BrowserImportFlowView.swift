import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserImportRequest: Identifiable {
    let id = UUID()
    let spaceID: UUID?
}

/// Independent of BrowserWorkSpaceDesignView. W47 can present this with its current
/// registry UUID, or post tatwo.browser.openImport with userInfo["spaceID"] = UUID.
struct BrowserImportFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var coordinator: BrowserImportCoordinator
    @State private var pickingPasswordFile = false
    private let onOpenBrowser: (UUID?) -> Void

    init(spaceID: UUID? = nil, onOpenBrowser: @escaping (UUID?) -> Void = { _ in }) {
        _coordinator = StateObject(wrappedValue: BrowserImportCoordinator(spaceID: spaceID))
        self.onOpenBrowser = onOpenBrowser
    }

    /// Injected fixture/preview state never reads a real browser profile or real vault.
    init(coordinator: BrowserImportCoordinator, onOpenBrowser: @escaping (UUID?) -> Void = { _ in }) {
        _coordinator = StateObject(wrappedValue: coordinator)
        self.onOpenBrowser = onOpenBrowser
    }

    private var animation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: BrowserSidebarMetrics.importAnimationDuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneCardPadding) {
            header
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, BrowserSidebarMetrics.childGap)
            }
            .animation(animation, value: coordinator.state)
            Divider()
            footer
        }
        .font(.system(size: BrowserSidebarMetrics.rowFontSize))
        .padding(BrowserSidebarMetrics.laneCardOuterInset)
        .frame(width: BrowserSidebarMetrics.importSheetWidth, height: BrowserSidebarMetrics.importSheetHeight)
        .background(.regularMaterial)
        .tint(LiquidGlassTokens.brandAccent)
        .interactiveDismissDisabled(coordinator.isRunning)
        .task { await coordinator.begin() }
        .onDisappear { coordinator.cancel() }
        .fileImporter(isPresented: $pickingPasswordFile, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): coordinator.selectPasswordFile(urls.first)
            case .failure: coordinator.passwordFileSelectionFailed()
            }
        }
        .accessibilityIdentifier("browser.import.flow")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.rowSpacing) {
            HStack {
                Text("從其他瀏覽器導入")
                    .font(.system(size: BrowserSidebarMetrics.importTitleSize, weight: .semibold))
                Spacer()
                Text("\(coordinator.state.step) / \(BrowserSidebarMetrics.importStepCount)")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(coordinator.state.step) 幕，共四幕")
            }
            HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                ForEach(1...BrowserSidebarMetrics.importStepCount, id: \.self) { step in
                    Capsule()
                        .fill(step <= coordinator.state.step ? LiquidGlassTokens.brandAccent : Color.secondary.opacity(LiquidGlassTokens.tintOpacity))
                        .frame(height: BrowserSidebarMetrics.spaceDotSize)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.state {
        case .idle:
            ProgressView("尋找已安裝的瀏覽器…")
        case .chooseSource:
            sourceChoices
        case .chooseData:
            dataChoices
        case .keychainNotice:
            passwordNotice
        case .running(let progress):
            progressContent(progress)
        case .done(let summary):
            summaryContent(summary)
        case .failed(let reason):
            Label("未能完成導入", systemImage: "exclamationmark.triangle")
                .font(.system(size: BrowserSidebarMetrics.importTitleSize, weight: .semibold))
            Text(reason).foregroundStyle(.secondary)
            if coordinator.source == .safari { safariHelp }
            progressRows(coordinator.progress)
        }
    }

    private var sourceChoices: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneRowSpacing) {
            Text("把熟悉的書籤與分頁帶過來。").foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: BrowserSidebarMetrics.importSourceColumns),
                      spacing: BrowserSidebarMetrics.rowSpacing) {
                ForEach(coordinator.sources) { info in
                    Button { coordinator.selectSource(info.source) } label: {
                        HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                            Image(systemName: info.source.symbol)
                                .font(.system(size: BrowserSidebarMetrics.laneCardPadding))
                                .frame(width: BrowserSidebarMetrics.childLeadingInset)
                            VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                                Text(info.source.rawValue).fontWeight(.semibold)
                                Text(sourceStatus(info))
                                    .font(.system(size: BrowserSidebarMetrics.metaFontSize))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: BrowserSidebarMetrics.childGap)
                            if coordinator.source == info.source { Image(systemName: "checkmark.circle.fill") }
                        }
                        .padding(BrowserSidebarMetrics.laneRowSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(coordinator.source == info.source
                            ? LiquidGlassTokens.brandAccent.opacity(LiquidGlassTokens.tintOpacity)
                            : Color.secondary.opacity(LiquidGlassTokens.subtleFillOpacity),
                            in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
                    }
                    .buttonStyle(.plain).disabled(!info.canSelect)
                    .accessibilityAddTraits(coordinator.source == info.source ? [.isSelected] : [])
                    .accessibilityIdentifier("browser.import.source.\(info.source.id)")
                }
            }
            if let source = coordinator.source {
                Text(source.explanation).foregroundStyle(.secondary)
                if let info = coordinator.selectedSourceInfo, !info.profiles.isEmpty {
                    Picker("設定檔", selection: Binding(get: { coordinator.profileID }, set: { coordinator.selectProfile($0) })) {
                        ForEach(info.profiles) { profile in
                            Text("\(profile.name) · \(profile.directory.lastPathComponent)").tag(Optional(profile.id))
                        }
                    }
                }
                if source == .safari { safariHelp }
            }
            Text("Firefox 不支援。").font(.system(size: BrowserSidebarMetrics.metaFontSize)).foregroundStyle(.secondary)
        }
    }

    private func sourceStatus(_ info: BrowserImportSourceInfo) -> String {
        if info.source == .firefox { return "不支援" }
        if info.source == .safari { return "僅書籤 · \(info.isInstalled ? "已安裝" : "需要取用權")" }
        if !info.isInstalled { return "未安裝" }
        return info.profiles.isEmpty ? "已安裝 · 找不到設定檔" : "已安裝"
    }

    private var dataChoices: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneCardPadding) {
            Text("從 \(coordinator.source?.rawValue ?? "") 帶哪些資料過來？")
                .fontWeight(.semibold)
            Picker("導入至 Browser space", selection: Binding(get: { coordinator.spaceID }, set: { coordinator.selectSpace($0) })) {
                ForEach(coordinator.destinationSpaces) { space in Text(space.name).tag(Optional(space.id)) }
            }
            ForEach(ImportData.allCases) { kind in
                VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                    Toggle(isOn: Binding(get: { coordinator.selectedData.contains(kind) },
                                         set: { coordinator.setData(kind, selected: $0) })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!(coordinator.source?.availableData.contains(kind) ?? false))
                    Text(dataDetail(kind))
                        .font(.system(size: BrowserSidebarMetrics.metaFontSize))
                        .foregroundStyle(.secondary)
                        .padding(.leading, BrowserSidebarMetrics.childLeadingInset)
                    if kind == .passwords && coordinator.selectedData.contains(.passwords) {
                        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                            Button("或從 CSV 檔匯入…") { pickingPasswordFile = true }
                                .buttonStyle(.link)
                            if coordinator.hasPasswordFile {
                                Label("已選取 CSV 備援檔", systemImage: "checkmark.circle")
                                Button("改用瀏覽器直接導入") { coordinator.selectPasswordFile(nil) }
                            }
                            if let message = coordinator.passwordFileMessage {
                                Text(message).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, BrowserSidebarMetrics.childLeadingInset)
                    }
                }
            }
            if coordinator.source == .safari { safariHelp }
        }
    }

    private func dataDetail(_ kind: ImportData) -> String {
        if kind == .extensions { return "列出但不導入（2.0.7 尚未支援）" }
        guard coordinator.source?.availableData.contains(kind) == true else { return "此來源不提供" }
        switch kind {
        case .bookmarks: return "保留資料夾路徑，不取代既有書籤"
        case .history: return "最近 90 天，最多 5,000 筆"
        case .passwords: return "經 macOS 授權直接讀取瀏覽器密碼，存入 TATWO 保險庫"
        case .pinned: return "在選定空間開啟並釘選"
        case .extensions: return ""
        }
    }

    private var passwordNotice: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneCardPadding) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: BrowserSidebarMetrics.importHeroSize))
                .foregroundStyle(LiquidGlassTokens.brandAccent).accessibilityHidden(true)
            Text(coordinator.hasPasswordFile ? "從 CSV 備援檔導入" : "允許讀取密碼保護金鑰")
                .font(.system(size: BrowserSidebarMetrics.importTitleSize, weight: .semibold))
            if coordinator.hasPasswordFile {
                Text("CSV 含未加密密碼。只在記憶體解析，不建立副本；原始 CSV 不會自動刪除，請妥善保管或自行移除。")
            } else {
                Text("macOS 會詢問是否允許 TATWO OS 讀取 \(coordinator.source?.rawValue ?? "來源瀏覽器") 的密碼保護金鑰，請按『永遠允許』")
                Text("只在你按下「開始導入」後讀取，密碼只在記憶體解密，再寫入 TATWO 保險庫；暫存資料庫讀完即刪。")
                    .foregroundStyle(.secondary)
            }
            Text("若拒絕授權，會略過密碼，其它資料繼續導入。").foregroundStyle(.secondary)
            Button("略過密碼，繼續導入") { coordinator.skipPasswordsAndStart() }
        }
    }

    private var safariHelp: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.rowSpacing) {
            Text("若讀不到 Safari 書籤：系統設定 › 隱私權與安全性 › 完整磁碟取用權，允許 TATWO OS。必要時重新開啟 App 後再導入。")
                .foregroundStyle(.secondary)
            Button("打開系統設定") { NSWorkspace.shared.open(BrowserImportSources.fullDiskAccessURL) }
        }
    }

    private func progressContent(_ progress: BrowserImportProgress) -> some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneCardPadding) {
            HStack(spacing: BrowserSidebarMetrics.laneCardPadding) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(LiquidGlassTokens.tintOpacity),
                                    lineWidth: BrowserSidebarMetrics.importProgressStroke)
                    Circle().trim(from: 0, to: progress.fraction)
                        .stroke(LiquidGlassTokens.brandAccent, style: StrokeStyle(lineWidth: BrowserSidebarMetrics.importProgressStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress.fraction * 100))%").monospacedDigit()
                }
                .frame(width: BrowserSidebarMetrics.importProgressSize, height: BrowserSidebarMetrics.importProgressSize)
                .animation(animation, value: progress.fraction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("導入進度").accessibilityValue("\(Int(progress.fraction * 100))%")
                VStack(alignment: .leading, spacing: BrowserSidebarMetrics.rowSpacing) {
                    Text(coordinator.cancelRequested ? "正在停止…" : "正在帶入你的資料").fontWeight(.semibold)
                    Text("取消會保留已完成的項目，不影響來源瀏覽器。").foregroundStyle(.secondary)
                }
            }
            progressRows(progress)
        }
    }

    private func progressRows(_ progress: BrowserImportProgress) -> some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneRowSpacing) {
            ForEach(progress.kinds) { kind in
                let count = progress.counts[kind] ?? BrowserImportCount()
                HStack {
                    Label(kind.title, systemImage: kind.symbol)
                    Spacer()
                    Text(count.label).monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    if count.finished { Image(systemName: count.reason == nil ? "checkmark.circle" : "info.circle") }
                }
                if let reason = count.reason {
                    Text(reason).font(.system(size: BrowserSidebarMetrics.metaFontSize)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summaryContent(_ summary: BrowserImportSummary) -> some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneCardPadding) {
            Label(summary.cancelled ? "導入已取消" : (summary.hasIssues ? "導入結束，部分項目未導入" : "準備好了"),
                  systemImage: summary.cancelled ? "pause.circle" : "checkmark.circle")
                .font(.system(size: BrowserSidebarMetrics.importTitleSize, weight: .semibold))
            progressRows(summary.progress)
            if !summary.extensions.isEmpty {
                Text("找到的擴充功能").fontWeight(.semibold)
                ForEach(summary.extensions) { item in Text("\(item.name) · \(item.version)").foregroundStyle(.secondary) }
            }
            if coordinator.source == .safari && summary.hasIssues { safariHelp }
            Text("原瀏覽器的資料未被更動。").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
            if coordinator.canGoBack { Button("上一步") { coordinator.back() } }
            Spacer()
            if coordinator.isRunning {
                Button("取消") { coordinator.cancel() }.disabled(coordinator.cancelRequested).keyboardShortcut(.cancelAction)
            } else if case .done = coordinator.state {
                Button("打開 Browser space") { onOpenBrowser(coordinator.spaceID); dismiss() }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            } else if case .failed = coordinator.state {
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button("取消") { coordinator.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(coordinator.state == .keychainNotice || (coordinator.state == .chooseData && !coordinator.selectedData.contains(.passwords))
                       ? "開始導入" : "繼續") { coordinator.advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.canAdvance)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
