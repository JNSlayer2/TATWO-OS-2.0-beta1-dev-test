// OS2 composer：沿用原生输入；討論串改由斜線指令開啟，不常駐派出按鈕。
import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin

extension ChatPage {
    var composerIsContextual: Bool {
        composerFocused
        || !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !model.selectedThreadPluginIDs.isEmpty
        || !model.skillSuggestions.isEmpty
        || model.activePendingHandoff != nil
    }

    static func textEditorHasMarkedText() -> Bool {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let fieldEditor = window?.fieldEditor(false, for: nil) as? NSTextView,
           fieldEditor.hasMarkedText() {
            return true
        }
        if let textView = window?.firstResponder as? NSTextView,
           textView.hasMarkedText() {
            return true
        }
        return false
    }

    func composer(contentMaxWidth: CGFloat?, forceCompactToolbar: Bool = false) -> some View {
        let compactToolbar = forceCompactToolbar || (contentMaxWidth ?? ChatUILayout.chatColumnMaxWidth) < 720
        let composerTextMinimumHeight = surface == .window
            ? TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
            : TatwoChatTranscriptVisualMetrics.panelComposerTextMinimumHeight
        let composerTextMaximumHeight = surface == .window
            ? TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight
            : TatwoChatTranscriptVisualMetrics.panelComposerTextMaximumHeight
        let effectiveComposerTextHeight = min(
            composerTextMaximumHeight,
            max(composerTextMinimumHeight, composerTextHeight))
        return VStack(alignment: .leading, spacing: 8) {
            if model.mode != .cli {
                pendingHandoffChip
            }

            if !model.dispatchRooms.isEmpty && !model.isDiscussionTrayHidden {
                DispatchCard(model: model)
            }

            if !model.skillSuggestions.isEmpty {
                skillSuggestionRail
            }

            // 「/」斜線指令列：內嵌在輸入框上方(不浮層)，避免與上方目標狀態列重疊。
            let slashCmds = model.matchingSlashCommands
            if !slashCmds.isEmpty {
                slashCommandRail(slashCmds)
            }

            // 「@」全域搜尋列（Codex 式）：先在輸入框上方逐筆列出可搜尋的 issue，
            // 點選某一筆才釘進右側資訊卡；打字即時過濾。
            if model.issueAtMentionQuery != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Issue List")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    if model.issueAtMentionMatches.isEmpty {
                        Text("沒有符合的 issue")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    ForEach(Array(model.issueAtMentionMatches.enumerated()), id: \.element.id) { idx, entry in
                        let isSelected = model.issueMentionSelectedIndex == idx
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) {
                                model.pickIssueMention(entry)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(entry.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("Issue・\(entry.sourceReference)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                if isSelected {
                                    Text("↵")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                LiquidGlassTokens.brandAccent.opacity(isSelected ? 0.18 : 0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isSelected
                                            ? LiquidGlassTokens.brandAccent
                                            : Color.clear,
                                        lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("↑↓ 選取、Enter 釘選，或點擊：\(entry.title)")
                    }
                }
                .onAppear { model.reloadIssueList() }
            }

            VStack(alignment: .leading, spacing: 0) {
                ChatComposerTextView(
                    text: $model.prompt,
                    contentHeight: $composerTextHeight,
                    isFocused: composerFocused,
                    placeholder: model.mode == .cli ? "輸入命令" : "要求後續跟進變更",
                    isMonospaced: model.mode == .cli,
                    minimumHeight: composerTextMinimumHeight,
                    maximumHeight: composerTextMaximumHeight,
                    onSubmit: {
                        guard model.canSend else { return }
                        model.send()
                    },
                    onFocusChange: { focused in
                        composerFocused = focused
                    },
                    onSuggestionKey: { key in
                        model.mode == .cli ? false : model.handleComposerSuggestionKey(key)
                    },
                    onPasteImage: { pasteboard in
                        model.pasteClipboardImage(from: pasteboard)
                    })
                    .frame(height: effectiveComposerTextHeight)
                .padding(.horizontal, 20)
                .padding(.top, 15)
                .padding(.bottom, 8)

                if !model.droppedPaths.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(model.droppedPaths, id: \.self) { path in
                                droppedAttachmentChip(path)
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 6)
                }

                composerToolbar(compactToolbar: compactToolbar)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 8)
            }
            .frame(
                minHeight: surface == .window
                    ? TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight
                    : TatwoChatTranscriptVisualMetrics.panelComposerMinimumHeight)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)

            // 輸入框下方的狀態抽屜常駐，避免介面結構隨狀態跳動。
            // 普通執行進度仍留在 transcript；無抽屜專屬提醒時顯示中性 fallback。
            // 抽屜要黏在輸入框下緣：往上塞進輸入框底下(負 top padding) + 壓到輸入框
            // 後面(zIndex -1)，讓抽屜自己的平頂被輸入框蓋住，只露出下半段圓角。
            // 2026-08-20 使用者裁決：保留獨立梯形抽屜（不做一體化），
            // 極光只換玻璃皮——見 composerStatusBar 內的主題分支。
            if model.mode != .cli {
                composerStatusBar
                    .zIndex(-1)
                    .padding(.top, -13)
            }

            if model.mode == .cli, model.lastCommand != "尚未執行" {
                Text(model.lastCommand)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.routeChoice.engine == .claude {
                    Text(model.lastClaudeRouteReceiptStatus)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 0)
        .opacity(globalNoteOpen ? 0 : 1)
        .disabled(globalNoteOpen)
        .allowsHitTesting(!globalNoteOpen)
        .accessibilityHidden(globalNoteOpen)
        .onChange(of: globalNoteOpen) { open in
            if open { composerFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    // 微倒梯形（頂寬、底稍窄）：上緣切平(與聊天窗銜接處不要 r)，只圓下緣兩角。
    private struct RoundedInvertedTrapezoid: Shape {
        var sideSlope: CGFloat = 14
        var cornerRadius: CGFloat = 12
        func path(in rect: CGRect) -> Path {
            let pts = [
                CGPoint(x: rect.minX, y: rect.minY),               // 0 top-left (切平)
                CGPoint(x: rect.maxX, y: rect.minY),               // 1 top-right (切平)
                CGPoint(x: rect.maxX - sideSlope, y: rect.maxY),   // 2 bottom-right (圓)
                CGPoint(x: rect.minX + sideSlope, y: rect.maxY),   // 3 bottom-left (圓)
            ]
            func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
                let dx = to.x - from.x, dy = to.y - from.y
                let len = Swift.max(0.0001, (dx * dx + dy * dy).squareRoot())
                return CGPoint(x: dx / len, y: dy / len)
            }
            func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
                let dx = a.x - b.x, dy = a.y - b.y
                return (dx * dx + dy * dy).squareRoot()
            }
            var path = Path()
            let n = pts.count
            for i in 0..<n {
                let curr = pts[i]
                let prev = pts[(i - 1 + n) % n]
                let next = pts[(i + 1) % n]
                // 只圓下緣(index 2/3)；上緣(0/1)保持直角切平銜接聊天窗。
                let r = (i <= 1) ? 0 : Swift.min(cornerRadius, dist(prev, curr) / 2, dist(next, curr) / 2)
                let toPrev = unit(curr, prev), toNext = unit(curr, next)
                let p1 = CGPoint(x: curr.x + toPrev.x * r, y: curr.y + toPrev.y * r)
                let p2 = CGPoint(x: curr.x + toNext.x * r, y: curr.y + toNext.y * r)
                if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
                if r > 0 { path.addQuadCurve(to: p2, control: curr) }
            }
            path.closeSubpath()
            return path
        }
    }

    // 輸入框下方狀態欄：比主框稍窄、正常參與垂直排版、微倒梯形＋圓角。
    // 內容變動只動這條，不影響上方輸入框 → 不再吃字。
    var composerStatusBar: some View {
        let state = model.composerFooterState
        let hasActiveStatus = state.isActive
        let visibleStatusText = islandExceptionsCount.count > 0 ? islandExceptionsCount.text : state.presentationText
        // 2026-08-21 重大修復：composerHint 全 app 零渲染點（考古＝7/31
        // 方框移除／8/7 footer 改版遺孤），幾十處 flashComposerHint 全在
        // 對空氣喊話——這就是兩輪驗收「靜默丟棄」的顯示層真兇。hint
        // 借道既有抽屜顯示（不造新形狀），優先於中性狀態。
        let hint = model.composerHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let showsHint = islandExceptionsCount.count == 0 && !(hint ?? "").isEmpty
        let showsFeedbackLoginError = showsHint && hint == "請先登入github才能提交issue"
        // 2026-09-11 使用者：沒有額外提醒時梯形裡不要有字（抽屜形狀照舊）。
        // 2026-09-11 使用者：「工作中」從工具列搬進梯形，當作梯形的狀態。
        let showsWorking = model.isRunning && !showsHint && islandExceptionsCount.count == 0
        let isQuiet = !showsHint && islandExceptionsCount.count == 0 && state == .neutral && !showsWorking

        return HStack(spacing: 7) {
            if showsWorking {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            } else {
            Circle()
                .fill(
                    showsHint
                        ? LiquidGlassTokens.brandAccent
                        : (hasActiveStatus
                            ? composerStatusDotColor(for: state)
                            : Color.secondary.opacity(0.72)))
                .frame(width: 5, height: 5)
            }
            Text(showsHint ? (hint ?? "") : (showsWorking ? "工作中" : visibleStatusText))
                .font(.system(size: 11, weight: showsHint ? .semibold : .medium))
                .foregroundStyle(
                    showsHint
                        ? AnyShapeStyle(showsFeedbackLoginError ? Color.red : Color.primary.opacity(0.9))
                        : AnyShapeStyle(
                            hasActiveStatus
                                ? composerStatusTextColor(for: state)
                                : Color.secondary.opacity(0.88)))
                .lineLimit(1)
                .truncationMode(.tail)
                // 2026-09-11 使用者：沒有提醒時不要有字，但圓點恢復常駐。
                .opacity(isQuiet ? 0 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // 2026-09-11 使用者：梯形大小維持原樣（露出 28pt，總高同舊版 33），只把字調到露出段正中。
        // 真正被輸入框蓋住的只有 5pt：外層 VStack spacing 8 先吃掉 -13 裡的 8（實測截圖）。
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .padding(.top, 5)
        // 2026-08-20 使用者裁決：梯形抽屜保留，只換皮——極光穿玻璃
        // （霜面材質＋白紗提亮＋主題白描邊，斜邊照舊）；fable5 維持
        // 原本的灰梯形一位元不動。
        .background {
            if TatwoActivePalette.current.usesGlass {
                // 2026-08-20 使用者調參：太透→補極光身份漸變（與 composer
                // 面板同一 ultraworkGradient 語言），白紗降一階讓漸變透出。
                RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                            .fill(LiquidGlassTokens.ultraworkGradient)
                            .opacity(LiquidGlassTokens.glassIdentityFillOpacity * 1.6))
                    .overlay(
                        RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                            .fill(Color.white.opacity(0.12)))
            } else {
                RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .fill(Color.primary.opacity(0.075))
            }
        }
        .overlay {
            if TatwoActivePalette.current.usesGlass {
                RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .stroke(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
            } else {
                RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
        }
        .overlay {
            if islandFooterHovering {
                RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .fill(Color.primary.opacity(0.035))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 14)   // 略小於聊天輸入框寬
        .contentShape(Rectangle())
        .onHover { islandFooterHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsHint ? (hint ?? "") : visibleStatusText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { IslandExceptionsNavigation.openWork() }
        .animation(.easeInOut(duration: 0.15), value: state)
        .onTapGesture(count: 2) { globalNoteOpen = true }
        .onTapGesture(count: 1) { IslandExceptionsNavigation.openWork() }
        .task { await islandExceptionsCount.observe() }
    }

    func composerStatusTextColor(
        for state: ChatComposerFooterState
    ) -> Color {
        switch state {
        case .waitingAuthorization:
            LiquidGlassTokens.brandAccent
        case .recoveryRequired, .workContextUnbound, .routeCooldown:
            Color.secondary
        case .neutral:
            Color.secondary.opacity(0.88)
        }
    }

    func composerStatusDotColor(
        for state: ChatComposerFooterState
    ) -> Color {
        switch state {
        case .recoveryRequired, .routeCooldown:
            .red
        case .waitingAuthorization:
            LiquidGlassTokens.brandAccent
        case .workContextUnbound:
            .orange
        case .neutral:
            Color.secondary.opacity(0.72)
        }
    }

    func composerToolbar(compactToolbar: Bool) -> some View {
        ChatComposerToolbarRow(compact: compactToolbar) {
            // #7 ＋ 改聰明選單：不再直接跳檔案匯入；貼圖/附件/插入指令收在一顆入口，
            // MCP/工具已在右側資訊卡，這裡專注「把東西帶進這一輪對話」。
            Menu {
                Button {
                    if !model.pasteClipboardImage() {
                        model.flashComposerHint("剪貼簿沒有圖片")
                    }
                } label: { Label("貼上剪貼簿圖片", systemImage: "doc.on.clipboard") }

                Button { model.chooseAttachments() } label: {
                    Label("附加檔案…", systemImage: "paperclip")
                }

                Button { showIPadConnection = true } label: {
                    Label("連接 iPad…", systemImage: "ipad")
                }

                Divider()

                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) { showChatSearch = true }
                } label: { Label("搜尋對話…", systemImage: "magnifyingglass") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("加入內容：貼圖、附件、指令")
            .popover(isPresented: $showIPadConnection) {
                IPadChatConnectionView(
                    threadID: model.selectedThreadID,
                    close: { showIPadConnection = false },
                    openSettings: {
                        showIPadConnection = false
                        showSettingsPage = true
                    }
                )
                .frame(width: 360)
            }

            if model.mode == .cli {
                chip(systemImage: "terminal", text: "命令輸入直送")
            } else {
                codexPermissionMenu(compact: compactToolbar)
            }

            if model.queuedChatTurnCount > 0 {
                if model.chatQueuePaused {
                    Button {
                        model.resumeQueuedChatTurns()
                    } label: {
                        Label("\(model.queuedChatTurnCount)", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("繼續 \(model.queuedChatTurnCount) 個已暫停的插話")
                } else {
                    Label("\(model.queuedChatTurnCount)", systemImage: "text.bubble")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .help("\(model.queuedChatTurnCount) 個插話等待中")
                }
            }

            // 「工作中」已搬到下方梯形（2026-09-11 使用者）。

            Spacer(minLength: compactToolbar ? 8 : 14)

            if model.mode != .cli {
                modelCollaborationComposerPill(compact: compactToolbar)
            }

            if model.isRunning {
                if model.canSend {
                    composerSendButton(compactToolbar: compactToolbar)
                }
                composerStopButton
            } else {
                composerSendButton(compactToolbar: compactToolbar)
            }
        }
    }

    func composerSendButton(compactToolbar: Bool) -> some View {
        ChatComposerSendButton(enabled: model.canSend) { model.send() }
            .accessibilityLabel("送出")
            .accessibilityIdentifier("chat-composer-send")
            .accessibilityValue(model.sendAvailabilityDiagnostic)
            .accessibilityAction { model.send() }
            .help(model.isLocalIssueCommand || model.isLocalDiscussionCommand || model.isRunning
                  ? model.sendAvailabilityDiagnostic : "送出")
    }

    // 斜線指令列（打「/」內嵌浮現，不遮上方目標列）：橫向 chip；打字越多前綴越窄。
    // 當只剩一個符合(如「/go」)會標 ↵ 提示可直接 Enter 執行。
    func slashCommandRail(_ cmds: [ChatPageModel.SlashCommandItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Label("指令", systemImage: "slash.circle")
                        .font(.caption2.weight(.black)).foregroundStyle(.secondary)
                    ForEach(Array(cmds.enumerated()), id: \.element.id) { idx, item in
                        let isSelected = model.slashCommandSelectedIndex == idx
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) {
                                model.applySlashCommandSuggestion(item)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.cmd)
                                        .font(.system(size: 11.5, weight: .black, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Text(item.subtitle)
                                        .font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if cmds.count == 1 {
                                    Text("↵").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(
                                LiquidGlassTokens.brandAccent.opacity(isSelected ? 0.20 : 0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        isSelected
                                            ? LiquidGlassTokens.brandAccent
                                            : LiquidGlassTokens.brandAccent.opacity(0.18),
                                        lineWidth: isSelected ? 1.5 : 1))
                            .contentShape(Rectangle())
                        }
                        .id(item.id)
                        .buttonStyle(.plain)
                        .help("→ 選取、Enter 插入，或點擊插入 \(item.cmd)：\(item.subtitle)")
                    }
                }
                .padding(.horizontal, 9)
            }
            .onChange(of: model.slashCommandSelectedIndex) { _, selected in
                guard let selected, cmds.indices.contains(selected) else { return }
                // Follow keyboard selection, not every layout update, so trackpad
                // scrolling stays independent. No animation lag during key repeat.
                proxy.scrollTo(cmds[selected].id, anchor: .center)
            }
            .frame(height: 34)
        }
    }

    // #3 附件 chip：圖片顯真縮圖、影片顯播放圖示、其他 paperclip；可 × 移除。都可送出。
    @ViewBuilder
    func droppedAttachmentChip(_ path: String) -> some View {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let isImage = TatwoImageAssetStore.isImageCandidatePath(path)
        let isVideo = ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
        let name = model.droppedPathDisplayNames[path]
            ?? URL(fileURLWithPath: path).lastPathComponent
        if isImage {
            ChatLoadedImageAttachment(
                attachment: ChatInlineAttachment(path: path, name: name),
                gallery: model.droppedPaths
                    .filter { TatwoImageAssetStore.isImageCandidatePath($0) }
                    .map { ChatInlineAttachment(path: $0, name: model.droppedPathDisplayNames[$0]) },
                remove: { model.removeDroppedPath(path) })
        } else {
            HStack(spacing: 5) {
                Image(systemName: isVideo ? "play.rectangle.fill" : "paperclip")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .frame(width: 24, height: 24)
                    .background(LiquidGlassTokens.brandAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(name).font(.caption2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 92, alignment: .leading)
                Button { model.removeDroppedPath(path) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("移除")
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(LiquidGlassTokens.brandAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.12), lineWidth: 1))
        }
    }

    /// 停止鈕語意色（極光 P5 隔離，2026-08-20）：
    /// 「中止」由設計語言承擔——fable5 的 brandAccent 是赤陶暖色，天然帶
    /// 中止語意；極光的 brandAccent 是紫色，毫無停止暗示（fable5 決策
    /// 污染極光的實例）。極光改回紅系語意色，chrome（漸層/描邊/光暈）
    /// 結構照舊；fable5 一位元不動。
    var composerStopTint: Color {
        TatwoActivePalette.current.usesGlass
            ? Color(nsColor: .systemRed)
            : LiquidGlassTokens.brandAccent
    }

    var composerStopButton: some View {
        Button {
            // 中斷要二次確認：停止會打斷這輪回應與相關派工，誤觸就整批消失。
            guard TatwoInterruptConfirmationPresenter.confirm(kind: .composerStop) else { return }
            model.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            composerStopTint,
                            composerStopTint.opacity(0.78)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            Circle()
                .strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity))
        }
        .shadow(
            color: composerStopTint.opacity(LiquidGlassTokens.shadowOpacity),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY
        )
        .help("停止")
    }

    func modelCollaborationComposerPill(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 6) {
            modelMenu(compact: true)
            ultraworkComposerPill(compact: compact)
        }
        .frame(
            width: composerModelTriggerWidth(compact: true) + composerUltraworkTriggerWidth(compact: compact) + (compact ? 5 : 6),
            height: 24,
            alignment: .trailing
        )
        // /plan follows Codex: planning stays in the transcript and never
        // exposes execution configuration in the composer.
    }

    func ultraworkComposerPill(compact: Bool) -> some View {
        let isCollaborationActive = model.collaborationLevel != .off
        return Button {
            let willShow = !showUltraworkPanel
            if sliderArchProbeEnabled && !sliderWindowRouteProbeEnabled {
                sliderArchitectureProbeLog(
                    control: "composer-trigger",
                    event: "action",
                    value: willShow ? 1 : 0
                )
            }
            if willShow {
                prepareCollaborationSliderReveal()
            }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                showUltraworkPanel = willShow
                if willShow {
                    showSingleModelPanel = false
                    collaborationControlExpanded = true
                } else {
                    collaborationSliderRevealProgress = 0
                }
            }
        } label: {
            ChatComposerCollaborationLabel(
                compact: compact, active: isCollaborationActive,
                level: model.collaborationLevel.title, selected: showUltraworkPanel)
        }
        .buttonStyle(.plain)
        .sliderArchProbeAccessibilityIdentifier(
            "arch-probe-composer-trigger",
            enabled: sliderWindowRouteProbeEnabled || sliderArchProbeEnabled
        )
        // #44：改用 chatFloatingPanelOverlay（視窗內 overlay），不再用 NSPopover（系統灰外框清不掉）。
        .help(isCollaborationActive ? "Ultrawork 協作保持 \(model.collaborationLevel.title)" : "開啟 Ultrawork 協作設定")
    }

    @ViewBuilder
    func snapshotMenuOverlay(sidebarWidth: CGFloat, containerSize: CGSize) -> some View {
        // Export-only fixtures: these static overlays let UI-loop screenshots
        // compare menu proportions when native SwiftUI Menu/Popover surfaces do
        // not render inside NSHostingView bitmap export. They are not proof that
        // live AppKit menu chrome matches Codex App; keep live-popover parity as
        // a separate visual gate.
        switch snapshotMenu {
        case .none:
            EmptyView()
        case .permission:
            snapshotPermissionMenu
                .frame(width: 356)
                .offset(x: sidebarWidth + 38, y: max(104, containerSize.height - 456))
                .allowsHitTesting(false)
        case .model:
            snapshotModelMenu
                .offset(x: max(sidebarWidth + 300, containerSize.width - 430), y: max(72, containerSize.height - 356))
                .allowsHitTesting(false)
        }
    }

    var snapshotPermissionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("如何核准 Codex 操作？")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ForEach(TatwoPermissionPreset.allCases) { preset in
                snapshotPermissionRow(preset)
            }
        }
        .padding(.bottom, 10)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    func snapshotPermissionRow(_ preset: TatwoPermissionPreset) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permissionIcon(for: preset))
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    model.permissionPreset == preset
                        ? LiquidGlassTokens.brandAccent
                        : Color.secondary
                )
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        model.permissionPreset == preset
                            ? LiquidGlassTokens.brandAccent
                            : Color.primary
                    )
                Text(preset.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.permissionPreset == preset {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    func permissionIcon(for preset: TatwoPermissionPreset) -> String {
        switch preset {
        case .askFirst: "hand.raised"
        case .approveForMe: "checkmark.bubble"
        case .fullAccess: "exclamationmark.shield"
        case .configFile: "gearshape"
        }
    }

    func codexPermissionMenu(compact: Bool = false) -> some View {
        let preset = model.permissionPreset
        let tint = codexPermissionTint(for: preset)
        return Menu {
            ForEach(TatwoPermissionPreset.allCases) { preset in
                Button {
                    model.permissionPreset = preset
                } label: {
                    Label(
                        preset.displayName,
                        systemImage: model.permissionPreset == preset ? "checkmark.circle.fill" : "circle")
                }
                .help(preset.subtitle)
            }
            Divider()
            Text(model.permissionPreset.mappingSummary)
        } label: {
            ChatComposerPermissionLabel(
                symbol: permissionIcon(for: preset),
                title: model.effectivePermissionLabel(compact: compact), tint: tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .controlSize(.small)
        .help(model.effectivePermissionMappingSummary)
    }

    func codexPermissionTint(for preset: TatwoPermissionPreset) -> Color {
        switch preset {
        case .fullAccess:
            return Color.red.opacity(0.88)
        case .approveForMe:
            return Color.orange.opacity(0.86)
        case .askFirst, .configFile:
            return Color.secondary
        }
    }

    var snapshotModelMenu: some View {
        modelPickerPanel
            .frame(width: modelPickerPanelWidth)
    }

    var modelPickerPanelWidth: CGFloat {
        let compactWidth = modelPickerCompactPanelWidth
        if modelPickerRouteListExpanded { return max(compactWidth, 244) }
        return compactWidth
    }

    var modelPickerCompactPanelWidth: CGFloat {
        let route = model.routeChoice
        if route.supportsNativeReasoningControl && route.supportsNativeSpeedControl { return 244 }
        if route.supportsNativeReasoningControl { return 222 }
        if route.supportsNativeSpeedControl { return 218 }
        return min(max(CGFloat(route.title.count * 7 + 92), 176), 214)
    }

    var modelPickerRouteListHeight: CGFloat {
        let sections = ChatRouteChoice.brandSections(selectedID: model.selectedModel)
        let rowHeight = CGFloat(ChatRouteChoice.all.count) * 27
        let headerHeight = CGFloat(sections.count) * 22
        return min(rowHeight + headerHeight, 238)
    }

    var ultraworkPanelWidth: CGFloat {
        // Keep Ultrawork controls on one stable width from first open through
        // drag/release. Changing width while the pointer is dragging, or when
        // Off becomes S/M/L/XL/XXL, makes the popover anchor visibly shake.
        return 282
    }

    var sliderArchProbeEnabled: Bool {
        ProcessInfo.processInfo.environment["TATWO_SLIDER_ARCH_PROBE"] == "1"
    }

    var sliderWindowRouteProbeEnabled: Bool {
        SliderWindowRouteProbeLogger.isEnabled
    }

    func composerModelTriggerWidth(compact: Bool) -> CGFloat {
        ChatComposerModelLabel.width(compact: compact)
    }

    func composerUltraworkTriggerWidth(compact: Bool) -> CGFloat {
        ChatComposerCollaborationLabel.width(compact: compact)
    }

    func modelMenu(compact: Bool = false) -> some View {
        let route = model.routeChoice
        return Button {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
                let willShow = !showSingleModelPanel
                showUltraworkPanel = false
                collaborationSliderRevealProgress = 0
                showSingleModelPanel = willShow
                if !willShow {
                    modelPickerRouteListExpanded = false
                }
            }
        } label: {
            modelMenuTrigger(route: route, compact: compact)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        // #44：改用 chatFloatingPanelOverlay（視窗內 overlay），不再用 NSPopover。
        .help(route.profile.menuSubtitle)
    }

    func modelMenuTrigger(route: ChatRouteChoice, compact: Bool) -> some View {
        ChatComposerModelLabel(
            title: compactRouteLabel(route), suffix: modelMenuSecondaryLabel(route),
            compact: compact, selected: showSingleModelPanel)
    }

    func modelMenuSecondaryLabel(_ route: ChatRouteChoice) -> String? {
        if route.supportsNativeSpeedControl {
            return model.selectedSpeedTier.compactDisplayName
        }
        if route.supportsNativeReasoningControl {
            return model.selectedEffort.compactDisplayName
        }
        return nil
    }

    func compactRouteLabel(_ route: ChatRouteChoice) -> String {
        if route.title == "GPT-5.5" { return "5.5" }
        if route.title.hasPrefix("GPT-") { return route.title.replacingOccurrences(of: "GPT-", with: "") }
        if route.title.count > 8 { return String(route.title.prefix(8)) }
        return route.title
    }

    // Codex 式 model picker（使用者 #32）：模型 / 推理強度 各一摺疊列顯示當前值，進階(速度)摺疊；非長 flat list。
    var modelPickerPanel: some View {
        let route = model.routeChoice
        return VStack(alignment: .leading, spacing: 0) {
            // 模型 row（顯示當前模型，chevron 展開品牌分組列）
            modelPickerRouteFooter(route: route)

            // 推理強度 row（顯示當前強度，chevron 展開選項）
            if route.supportsNativeReasoningControl {
                modelPickerSectionDivider
                modelPickerHeaderRow(
                    title: "推理強度",
                    value: model.selectedEffort.displayName,
                    expanded: modelPickerEffortExpanded
                ) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        modelPickerEffortExpanded.toggle()
                        if modelPickerEffortExpanded {
                            modelPickerRouteListExpanded = false
                            modelPickerAdvancedExpanded = false
                        }
                    }
                }
                if modelPickerEffortExpanded {
                    ForEach(route.allowedEfforts) { modelPickerEffortRow($0) }
                }
            }

            // 進階（速度）摺疊
            if route.supportsNativeSpeedControl {
                modelPickerSectionDivider
                modelPickerHeaderRow(
                    title: "進階",
                    value: modelPickerAdvancedExpanded ? "" : "速度 · \(model.selectedSpeedTier.displayName)",
                    expanded: modelPickerAdvancedExpanded
                ) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        modelPickerAdvancedExpanded.toggle()
                        if modelPickerAdvancedExpanded {
                            modelPickerRouteListExpanded = false
                            modelPickerEffortExpanded = false
                        }
                    }
                }
                if modelPickerAdvancedExpanded {
                    Text("速度")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    ForEach(route.allowedSpeedTiers) { modelPickerSpeedRow($0) }
                }
            }
        }
        .padding(.vertical, 6)
        // #46/#47：改用真 /liquid-glass-dashboard WebGL 玻璃底板（透明、有折射），非白 SwiftUI 近似。
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    var modelPickerSectionDivider: some View {
        Divider().opacity(0.12).padding(.horizontal, 10).padding(.vertical, 2)
    }

    // Codex 式摺疊列：標題 + 當前值 + chevron。
    func modelPickerHeaderRow(
        title: String,
        value: String,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .lineLimit(1)
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 31)
            .contentShape(Rectangle())
            .chatMenuRowHover()
        }
        .buttonStyle(.plain)
    }

    var ultraworkCollaborationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sliderWindowRouteProbeEnabled {
                sliderWindowRouteProbePanel
            } else if sliderArchProbeEnabled {
                sliderArchitectureProbePanel
            } else {
                collaborationStrengthSlider(level: model.collaborationLevel)
            }
        }
        .padding(10)
        // #46/#47：改用真 /liquid-glass-dashboard WebGL 玻璃底板（透明、有折射）。
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    @ViewBuilder
    var planUltraworkCanvasPanel: some View {
        if ultraworkRolePickerTarget != nil {
            collaborationRoleModelPickerPanel
        } else {
            ultraworkCollaborationPanel
        }
    }

    var sliderWindowRouteProbePanel: some View {
        VStack(spacing: 8) {
            Text("WINDOW ROUTE PROBE · POPOVER")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 252, height: 16)

            Button {
                sliderWindowRouteProbeButtonCount += 1
                SliderWindowRouteProbeLogger.logAction(
                    control: "swiftui-button-a",
                    value: Double(sliderWindowRouteProbeButtonCount)
                )
            } label: {
                Text("A · SwiftUI Button · \(sliderWindowRouteProbeButtonCount)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 252, height: 34)
            .accessibilityIdentifier("arch-probe-button-a")

            SliderWindowRouteProbeButton(
                title: "P · Native AppKit NSButton · \(sliderWindowRouteProbeNativeCount)"
            ) {
                sliderWindowRouteProbeNativeCount += 1
                SliderWindowRouteProbeLogger.logAction(
                    control: "popover-native",
                    value: Double(sliderWindowRouteProbeNativeCount)
                )
            }
            .frame(width: 252, height: 34)
            .accessibilityIdentifier("window-route-probe-popover-native")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    var sliderArchitectureProbePanel: some View {
        VStack(spacing: 8) {
            Button {
                sliderArchProbeButtonCount += 1
                sliderArchitectureProbeLog(
                    control: "button-a",
                    event: "action",
                    value: Double(sliderArchProbeButtonCount)
                )
            } label: {
                Text("A · Plain SwiftUI Button · \(sliderArchProbeButtonCount)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 252, height: 34)
            .accessibilityIdentifier("arch-probe-button-a")

            sliderArchitectureProbeVisibleSlider
            sliderArchitectureProbeCurrentComposition
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    var sliderArchitectureProbeVisibleSlider: some View {
        let value = Binding<Double>(
            get: { sliderArchProbeVisibleValue },
            set: { newValue in
                sliderArchProbeVisibleValue = newValue
                sliderArchitectureProbeLog(
                    control: "visible-slider-b",
                    event: "value",
                    value: newValue
                )
            }
        )
        return Slider(value: value, in: 0...1) {
            Text("B · Visible native Slider")
        } minimumValueLabel: {
            Text("B")
        } maximumValueLabel: {
            Text("NATIVE")
        } onEditingChanged: { editing in
            sliderArchitectureProbeLog(
                control: "visible-slider-b",
                event: editing ? "editing-began" : "editing-ended",
                value: sliderArchProbeVisibleValue
            )
        }
        .frame(width: 252, height: 34)
        .accessibilityIdentifier("arch-probe-visible-slider-b")
    }

    var sliderArchitectureProbeCurrentComposition: some View {
        let width: CGFloat = 252
        let laneInset = min(max(width * 0.065, 16), 22)
        let laneWidth = width - (laneInset * 2)
        let value = Binding<Double>(
            get: { sliderArchProbeCompositionValue },
            set: { newValue in
                sliderArchProbeCompositionValue = newValue
                sliderArchitectureProbeLog(
                    control: "current-composition-c",
                    event: "value",
                    value: newValue
                )
            }
        )
        let glassProgress = max(CGFloat(0.12), CGFloat(sliderArchProbeCompositionValue))
        let trackSaturation = 0.50 + (sliderArchProbeCompositionValue * 0.50)
        let labels = ["S", "M", "L", "XL"]

        return Slider(
            value: value,
            in: 0...1,
            onEditingChanged: { editing in
                sliderArchitectureProbeLog(
                    control: "current-composition-c",
                    event: editing ? "editing-began" : "editing-ended",
                    value: sliderArchProbeCompositionValue
                )
            }
        ) {
            Text("C · Current composition clone")
        }
        .labelsHidden()
        .focusable(false)
        .clipShape(ChatSliderVisualSuppressionShape())
        .frame(width: width, height: 34)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.92, green: 0.48, blue: 1.00).opacity(0.42),
                                Color(red: 0.60, green: 0.53, blue: 1.00).opacity(0.34),
                                Color(red: 0.60, green: 0.78, blue: 1.00).opacity(0.24),
                                Color(red: 1.00, green: 0.70, blue: 0.86).opacity(0.36)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .saturation(trackSaturation)

#if os(macOS)
                // Accessibility identity names the concrete branch. Alpha is
                // rendering state and must not be used as branch identity.
                LiquidGlassDashboardSliderMaterial(
                    progress: glassProgress,
                    isVisible: true
                )
                .frame(width: width, height: 34)
                .clipShape(Capsule())
                .accessibilityIdentifier("branch=lgd-material")
                .accessibilityHidden(true)
#endif

                ForEach(Array(labels.enumerated()), id: \.offset) { item in
                    let index = item.offset
                    let title = item.element
                    let optionX = laneInset + (laneWidth * CGFloat(index) / CGFloat(labels.count - 1))
                    Text(title)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.28, green: 0.15, blue: 0.46).opacity(0.68))
                        .frame(width: title == "XL" ? 22 : 18, height: 14)
                        .position(x: optionX, y: 17)
                }

                Text("C · CURRENT COMPOSITION")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .padding(.horizontal, 6)
                    .frame(height: 14)
                    .background(Color.black.opacity(0.56), in: Capsule())
                    .position(x: width / 2, y: 7)
            }
            .frame(width: width, height: 34)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("arch-probe-current-composition-c")
    }

    func sliderArchitectureProbeLog(
        control: String,
        event: String,
        value: Double
    ) {
        guard sliderArchProbeEnabled else { return }
        let line = String(
            format: "source=arch-probe control=%@ event=%@ value=%.4f\n",
            control,
            event,
            value
        )
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/tatwo-slider-arch-probe.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    func modelPickerRouteFooter(route: ChatRouteChoice) -> some View {
        let brandSections = ChatRouteChoice.brandSections(selectedID: model.selectedModel)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                    modelPickerRouteListExpanded.toggle()
                    // 三段互斥：展開模型就收推理/進階（sol Verifier）。
                    if modelPickerRouteListExpanded {
                        modelPickerEffortExpanded = false
                        modelPickerAdvancedExpanded = false
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("模型")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(model.modelPickerRouteLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .lineLimit(1)
                    Image(systemName: modelPickerRouteListExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 31)
                .contentShape(Rectangle())
                .chatMenuRowHover()
            }
            .buttonStyle(.plain)

            if modelPickerRouteListExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(brandSections) { section in
                            modelPickerBrandHeader(section.brand)
                            ForEach(section.choices) { choice in
                                modelPickerInlineRouteRow(choice)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                    .padding(.bottom, 3)
                }
                .frame(height: modelPickerRouteListHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    func modelPickerBrandHeader(_ brand: ChatRouteBrandGroup) -> some View {
        Text(brand.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }

    func selectRouteChoice(_ choice: ChatRouteChoice) {
        // Close the picker first, then mutate the route on the next runloop
        // tick. modelPickerPanelWidth/modelPickerCompactPanelWidth read
        // model.routeChoice, so mutating it before the popover has started
        // dismissing made the panel visibly resize while still on screen.
        withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
            modelPickerRouteListExpanded = false
            showSingleModelPanel = false
        }
        DispatchQueue.main.async {
            model.setSingleModel(choice.id, syncCollaborationLead: model.collaborationLevel != .off)
            if choice.supportsNativeReasoningControl, !choice.allowedEfforts.contains(model.selectedEffort) {
                model.selectedEffort = choice.defaultEffort
            }
            if choice.supportsNativeSpeedControl, !choice.allowedSpeedTiers.contains(model.selectedSpeedTier) {
                model.selectedSpeedTier = choice.defaultSpeedTier ?? choice.allowedSpeedTiers.first ?? .fast
            }
        }
    }

    func modelPickerInlineRouteRow(_ choice: ChatRouteChoice) -> some View {
        let isSelected = model.selectedModel == choice.id
        let isPending = model.pendingModelID == choice.id
        return Button {
            selectRouteChoice(choice)
        } label: {
            HStack(spacing: 8) {
                Text(choice.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isPending {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .black))
                        .accessibilityLabel("下一輪")
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                }
            }
            .foregroundStyle(
                isSelected || isPending
                    ? LiquidGlassTokens.brandAccent
                    : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 27)
            .contentShape(Rectangle())
            .chatMenuRowHover(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    func modelPickerSpeedRow(_ speed: TatwoModelSpeedTier) -> some View {
        let isSelected = model.selectedSpeedTier == speed
        return Button {
            model.selectedSpeedTier = speed
        } label: {
            HStack(spacing: 8) {
                Text(speed.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                }
            }
            .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .contentShape(Rectangle())
            .chatMenuRowHover(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    func modelPickerEffortRow(_ effort: TatwoCodexReasoningEffort) -> some View {
        let isSelected = model.selectedEffort == effort
        return Button {
            model.selectedEffort = effort
        } label: {
            HStack(spacing: 8) {
                Text(effort.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .black))
                }
            }
            .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .contentShape(Rectangle())
            .chatMenuRowHover(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let path = ChatDropPathDecoder.path(from: item)
                    guard let path else { return }
                    Task { @MainActor in model.appendDroppedPath(path) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, error in
                    guard error == nil, let data else {
                        Task { @MainActor in
                            model.flashComposerHint("拖入的圖片無法讀取。")
                        }
                        return
                    }
                    Task { @MainActor in
                        model.appendDroppedImageData(data, suggestedName: "拖入的圖片.png")
                    }
                }
            }
        }
        return accepted
    }
}
