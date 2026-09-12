// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/CLISessionTree.swift；改動 446 行（原因：沿用 cli-ui 抽取原列；修正拖放手勢與原生文字型別，牛皮紙解析既有次要文字色；未新增型別）
import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ChatPage {
    var cliSessionsRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.cliRailTabs.isEmpty && model.cliRailHistory.isEmpty {
                cliRailEmptyState("還沒有終端機。按 ＋ 開一個，或從 Chat 右鍵『在 CLI 開啟專案』。")
            }
            ForEach(model.cliRailTabs) { session in
                cliManagedSessionRow(session)
            }
            if !model.cliRailHistory.isEmpty {
                Text("先前的終端機")
                    .font(ChatTypography.systemUI(11.5, weight: .semibold))
                    .foregroundStyle(TatwoActivePalette.current.usesGlass ? Color.secondary : Color.primary.opacity(0.62))
                    .padding(.horizontal, 9)
                ForEach(model.cliRailHistory) { record in
                    cliPreviousSessionRow(record)
                }
            }
        }
        // The matte paper palette is light even when the window exports in dark appearance.
        // Resolve the existing primary/secondary semantic tokens against that paper surface.
        .transformEnvironment(\.colorScheme) { if !TatwoActivePalette.current.usesGlass { $0 = .light } }
        .alert("終端機改名", isPresented: $model.cliRenamePresented) {
            TextField("名稱", text: $model.cliRenameTitle)
            Button("儲存") { model.commitCLIRename() }
            Button("取消", role: .cancel) { }
        }
    }

    private func cliRailEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .allowsHitTesting(false)
    }

    private func cliManagedSessionRow(_ session: TatwoNativeCLISessionBook.Session) -> some View {
        let isSelected = model.activeCLITabID == session.id
        let isHovered = model.cliRailHoveredID == session.id
        return HStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: cliRailEngineIcon(session.engine))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : (TatwoActivePalette.current.usesGlass ? Color.secondary : Color.primary.opacity(0.55)))
                    .frame(width: 14, height: 18)
                Text(session.title)
                    .onTapGesture(count: 2) { model.beginCLIRename(session.id, title: session.title) }
                    .font(ChatTypography.sidebarThreadTitle.weight(isSelected ? .bold : .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : (TatwoActivePalette.current.usesGlass ? Color.primary : Color.primary.opacity(0.8)))
                if model.cliUIRecord(session.id)?.pinned == true {
                    Image(systemName: "pin.fill").font(.caption2)
                }
                cliSessionStatusLabel(session.id, compact: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectCLITab(session.id) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selectCLITab(session.id) }

            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .help("關閉分頁")
                .highPriorityGesture(TapGesture().onEnded {
                    model.closeCLITab(session.id)
                })
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LiquidGlassTokens.brandAccent.opacity(0.10))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            model.cliRailHoveredID = hovering ? session.id : nil
        }
        .chatMenuRowHover(isSelected: isSelected)
        .onDrag { model.cliRailDragProvider(session.id) }
        .onDrop(of: [ChatPageModel.cliRailDragType], isTargeted: nil) { providers in
            model.handleCLIRailDrop(providers, before: session.id)
        }
        .contextMenu {
            Button("改名") { model.beginCLIRename(session.id, title: session.title) }
            Button(model.cliUIRecord(session.id)?.pinned == true ? "取消釘選" : "釘選") {
                model.pinCLITab(session.id, pinned: model.cliUIRecord(session.id)?.pinned != true)
            }
            Button("把輸出丟回 Chat") { cliReturnOutputToChat(session.id) }
            Button("關閉") { model.closeCLITab(session.id) }
        }
    }

    private func cliRailEngineIcon(_ engine: TatwoNativeCLISessionBook.Engine) -> String {
        switch engine {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .grok: return "bolt.fill"
        case .generic: return "terminal"
        }
    }

    private func cliPreviousSessionRow(_ record: CLISessionStore.Record) -> some View {
        let isSelected = false
        return Button {
            Task { await model.restoreCLIRailTab(record.id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: cliRailEngineIcon(TatwoNativeCLISessionBook.Engine(rawValue: record.engine) ?? .generic))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : (TatwoActivePalette.current.usesGlass ? Color.secondary : Color.primary.opacity(0.55)))
                    .frame(width: 14, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(ChatTypography.sidebarThreadTitle.weight(isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : (TatwoActivePalette.current.usesGlass ? Color.primary : Color.primary.opacity(0.8)))
                    Text("\(URL(fileURLWithPath: record.cwd).lastPathComponent) · 上次 \(model.cliRelativeLastActive(record))")
                        .font(ChatTypography.sidebarThreadPreview)
                        .foregroundStyle(TatwoActivePalette.current.usesGlass ? Color.secondary : Color.primary.opacity(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LiquidGlassTokens.brandAccent.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover(isSelected: isSelected)
        .disabled(model.cliRestoringIDs.contains(record.id))
    }

    func cliSessionStatusLabel(_ id: UUID, compact: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(compact ? "●" : model.cliUIStatusLabel(id))
                .foregroundStyle(model.cliUIStatusColor(id))
            if model.cliTabStatus(id) == .exited, let code = model.cliUIRecord(id)?.exitCode, code != 0 {
                Text("exit \(code)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 10, weight: .bold).monospaced())
        .help(model.cliUIStatusLabel(id))
        .accessibilityLabel(model.cliUIStatusLabel(id))
    }

    func cliReturnOutputToChat(_ id: UUID) {
        guard !model.cliTabScrollback(id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let window = NSApp.keyWindow
        model.sendCLITabOutputToChat(id)
        model.mode = .chat
        Task { @MainActor [weak window] in
            // Wait for the existing NSViewRepresentable to attach, not just a model focus flag.
            for _ in 0..<20 {
                guard model.mode == .chat, let window, window.isKeyWindow else { return }
                if let root = window.contentView, let editor = cliComposerEditor(in: root) {
                    window.makeFirstResponder(editor)
                    composerFocused = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func cliComposerEditor(in view: NSView) -> ChatComposerTextView.ComposerNSTextView? {
        if let editor = view as? ChatComposerTextView.ComposerNSTextView,
           editor.accessibilityTextLabel == "Chat message" { return editor }
        return view.subviews.lazy.compactMap { cliComposerEditor(in: $0) }.first
    }
}
