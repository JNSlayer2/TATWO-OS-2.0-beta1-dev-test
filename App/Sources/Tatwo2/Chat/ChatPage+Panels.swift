// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage+Panels.swift；改動 5 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin

extension ChatPage {
    var isPanel: Bool { surface == .panel }
    var composerMaxWidth: CGFloat? {
        guard surface == .window, model.mode == .chat else { return nil }
        // Codex App keeps the chat column readable, but the current desktop
        // baseline is wider than a mobile chat column. 60fps references use a
        // foreground card that can breathe inside the canvas; do the same here
        // without letting the composer stretch edge-to-edge.
        return ChatUILayout.chatColumnMaxWidth
    }
    var mainPaneVerticalSpacing: CGFloat {
        model.mode == .chat && model.shouldShowActiveGoalInlineCard ? 6 : 12
    }
    func mainPane(contentMaxWidth: CGFloat?, forceCompactToolbar: Bool = false) -> some View {
        VStack(spacing: mainPaneVerticalSpacing) {
            if model.mode == .bot {
                // 金樣快照維持 Gen-4 12 場景（凍結的視覺基線不動）；
                // 互動 runtime 走 Gen-5 工作室版（2026-09-09 使用者收斂）。
                if BotPageRootView.snapshotExportMode && !BotStudioRootView.exportGen5 {
                    BotPageRootView.forScene(Self.botExportScene ?? "rail-tree", onSwitchMode: { newMode in
                        withAnimation(.easeInOut(duration: 0.14)) { model.mode = newMode }
                    })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BotStudioRootView(mode: BotStudioRootView.exportGen5Mode, onSwitchMode: { newMode in
                        withAnimation(.easeInOut(duration: 0.14)) { model.mode = newMode }
                    })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.mode == .browser {
                if ChatRunMode.browserPreviewEnabled {
                    BrowserWorkSpaceDesignView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Fail closed even for a stale selection or mode notification.
                    Color.clear
                        .onAppear { model.mode = .chat }
                }
            } else if model.mode == .cli {
                // 2026-08-23 sol 一致性收尾 R2：loops 僅留在 chat 右欄；
                // CLI 主畫面固定為右上、多卡向下排列的終端工作區。
                cliTerminalPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else {
                messageArea(contentMaxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.mode == .chat,
               model.selectedThreadHasWorkOSGoal
            {
                activeGoalInlineCard(contentMaxWidth: contentMaxWidth)
                    .frame(maxWidth: contentMaxWidth ?? composerMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if model.mode != .cli, model.mode != .bot, model.mode != .browser {
                composer(contentMaxWidth: contentMaxWidth, forceCompactToolbar: forceCompactToolbar)
                    .frame(maxWidth: contentMaxWidth ?? composerMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // #44：ultrawork / model picker 改視窗內 overlay（非 NSPopover）。scrim 在後、面板在前，z-order 正確。
        .overlay(alignment: .bottom) { chatFloatingPanelOverlay(contentMaxWidth: contentMaxWidth) }
    }

    @ViewBuilder
    func chatFloatingPanelOverlay(contentMaxWidth: CGFloat?) -> some View {
        if !planInspectorPresented
            && (showUltraworkPanel || showSingleModelPanel
                || ultraworkRolePickerTarget != nil)
        {
            ZStack(alignment: .bottom) {
                // 點面板外關閉（協作滑桿拖曳中不關）。scrim 在最底層。
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !(collaborationSliderEditing || collaborationSliderSettling) else { return }
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                            showUltraworkPanel = false
                            showSingleModelPanel = false
                            ultraworkRolePickerTarget = nil
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // #46/#47 位置修：面板約束到 composer 寬度並置中→trailing 對齊 composer 右緣(trigger 所在)，
                // padding.bottom 抬到 composer 上方，不再飄到 mainPane 右外側。
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Group {
                        if ultraworkRolePickerTarget != nil {
                            collaborationRoleModelPickerPanel
                                .frame(
                                    width: modelPickerPanelWidth,
                                    alignment: .leading)
                        } else if showUltraworkPanel {
                            ultraworkCollaborationPanel.frame(width: ultraworkPanelWidth)
                        } else if showSingleModelPanel {
                            modelPickerPanel.frame(width: modelPickerPanelWidth, alignment: .leading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
                // sol Verifier: 用與 composer 相同的 contentMaxWidth，不再固定 820，否則窄視窗右緣偏移。
                .frame(maxWidth: contentMaxWidth ?? composerMaxWidth ?? ChatUILayout.chatColumnMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 104)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    var workspaceUtilityContextMenu: some View {
        if model.archivedThreadCount > 0 {
            Button {
                model.restoreMostRecentArchivedThread()
            } label: {
                Label(
                    "還原最近封存 (\(model.archivedThreadCount))",
                    systemImage: "arrow.uturn.backward")
            }
            Divider()
        }

        Button {
            model.exportHandoffPack()
        } label: {
            Label("匯出交接包", systemImage: "square.and.arrow.up")
        }
        Button {
            model.importHandoffPack()
        } label: {
            Label("匯入交接包", systemImage: "square.and.arrow.down")
        }
        Button {
            showComputerUseInfo = true
        } label: {
            Label("Computer Use 評估", systemImage: "cursorarrow.click.2")
        }

        if model.shouldOfferCodexMirrorOptIn {
            Divider()
            Button {
                model.enableCodexThreadMirror()
            } label: {
                Label(
                    model.isEnablingCodexMirror
                        ? "啟用 Codex 鏡射中…"
                        : "啟用 Codex thread 鏡射 · \(model.codexMirrorStatusMessage)",
                    systemImage: model.codexMirrorStatus == .unavailable
                        ? "externaldrive.badge.exclamationmark"
                        : "externaldrive")
            }
            .disabled(model.isEnablingCodexMirror)
        }

        if model.canOpenThreadInCLI {
            Divider()
            // chat→cli 閉環：一鍵把此討論串的專案工作目錄在 CLI 開一個 Shell 分頁。
            Button {
                model.openThreadProjectInCLI()
                infoCardFloatingOpen = false
            } label: {
                Label("在 CLI 開啟工作目錄", systemImage: "terminal")
            }
        }
    }

    // 懸浮資訊卡浮層：threadInfoCard 包玻璃底、頂右錨定在 strip 下方、點外關閉、hug 內容（同 ultrawork 浮層樣式）。
    // 使用者 2026-07-12：資訊卡要懸浮，不是開右側頁。
    var chatFloatingInfoCardOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        infoCardFloatingOpen = false
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            threadInfoCard
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(width: 336, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                .padding(.top, 44)
                .padding(.trailing, WindowChromeMetrics.headerHorizontalInset)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 設定整頁：置中玻璃卡（暗幕點外關閉）；穩定 overlay，不受工具列刷新影響。
    var tatwoSettingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea(.container, edges: .all)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.18)) { showSettingsPage = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TatwoSettingsPage(model: model, initialSection: updateSettingsSection) {
                withAnimation(.easeOut(duration: 0.18)) { showSettingsPage = false }
            }
            .onDisappear { updateSettingsSection = nil }
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 10)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 額度 Live quota 浮層：錨定左下（貼近 OS 選單），自繪 provider 段列＋完整 Usage 連結。
    var liveQuotaOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { showLiveQuota = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            let quotaModel = HeaderQuotaStripModel(
                providers: quotaProviders,
                snapshot: initialLiveQuotaSnapshot ?? .loading)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                    Text("Live quota")
                        .font(ChatTypography.systemUI(13, weight: .bold))
                    Spacer(minLength: 0)
                }
                if quotaModel.segments.isEmpty {
                    Text("沒有啟用中的 provider")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(quotaModel.segments) { segment in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 6, height: 6)
                            Text(segment.displayName)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(segment.remainingPercent.map { "\($0)%" } ?? "—")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().opacity(0.4)
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { showLiveQuota = false }
                    NotificationCenter.default.post(
                        name: .tatwoOpenStatusPanel, object: TatwoPage.usage.rawValue)
                } label: {
                    HStack(spacing: 6) {
                        Text("完整 Usage")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(width: 236, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
            .padding(.leading, 12)
            .padding(.bottom, 52)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var chatModeOSMenuButton: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                showOSMenu.toggle()
            }
        } label: {
            TatwoOSMark(size: 12)
                .frame(minWidth: 44, minHeight: 36, alignment: .center)
                .contentShape(Rectangle())
                .opacity(showOSMenu ? 1 : 0.92)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("TATWO OS")
        .help("TATWO OS")
        .padding(.leading, 12)
        .padding(.bottom, 12)
    }

    // TATWO OS 布標點擊後的標準浮層：與主題選擇器同一玻璃樣式；設定為可點擊進入(非 hover 展開)。
    var tatwoOSMenuOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { showOSMenu = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TatwoOSMark(size: 14)
                    Spacer(minLength: 0)
                }
                osMenuRow(title: "設定", icon: "slider.horizontal.3", chevron: true) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { showOSMenu = false }
                    showSettingsPage = true
                }
                osMenuRow(title: "風格", icon: "paintpalette", chevron: false) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        showOSMenu = false
                        showThemePicker = true
                    }
                }
                osMenuRow(title: "額度", icon: "gauge.with.dots.needle.bottom.50percent", chevron: false) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        showOSMenu = false
                        showLiveQuota = true
                    }
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
            .padding(.leading, 12)
            .padding(.bottom, 52)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func osMenuRow(
        title: String, icon: String, chevron: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .frame(width: 18)
                Text(title)
                    .font(ChatTypography.systemUI(12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 設定/主題/選擇主題浮層（使用者 #54）：主題卡列表 + 三色色票 + 選中勾 + fable5 紀念文字。錨定左下、點外關閉。
    var chatThemePickerOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { showThemePicker = false }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("選擇主題").font(ChatTypography.systemUI(14, weight: .bold))
                    Text("設定 / 主題").font(ChatTypography.systemUI(11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(TatwoTheme.all) { theme in
                    themePickerRow(theme)
                }
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
            .padding(.leading, 12)
            .padding(.bottom, 52)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func themePickerRow(_ theme: TatwoTheme) -> some View {
        let isActive = themeStore.activeThemeID == theme.id
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) { themeStore.select(theme.id) }
        } label: {
            HStack(spacing: 12) {
                // 主題縮影（2026-08-20 使用者裁決：UI 是優先語言）——
                // 直接展示主題長相：自己的底、自己的氛圍漸變、自己的
                // 面卡語言（玻璃亮卡 vs 暖紙卡），不靠文字想像。
                themeSwatchPreview(theme, isActive: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.id.displayName).font(ChatTypography.systemUI(13, weight: .semibold))
                    Text(theme.id.subtitle).font(ChatTypography.systemUI(10.5))
                        .foregroundStyle(.secondary)
                    if let text = theme.commemorativeText {
                        Text(text).font(ChatTypography.systemUI(10, weight: .medium))
                            .foregroundStyle(LiquidGlassTokens.brandAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? LiquidGlassTokens.brandAccent : Color.secondary.opacity(0.5))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? LiquidGlassTokens.brandAccent.opacity(0.10) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 主題縮影卡：canvasBase 打底、三彩氛圍漸變、迷你面卡示範該主題的
    /// surface 語言；選中以 brandAccent 外環標示（設計語言，非文字）。
    func themeSwatchPreview(_ theme: TatwoTheme, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.palette.canvasBase)
            .overlay {
                LinearGradient(
                    colors: [
                        theme.palette.accentPink.opacity(0.5),
                        theme.palette.accentViolet.opacity(0.42),
                        theme.palette.accentBlue.opacity(0.5)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(theme.palette.usesGlass ? 0.55 : 0.26)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        theme.palette.usesGlass
                            ? AnyShapeStyle(Color.white.opacity(0.55))
                            : AnyShapeStyle(theme.palette.surfaceFill))
                    .frame(width: 26, height: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(theme.palette.surfaceBorder.opacity(0.6), lineWidth: 0.5))
                    .padding(5)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(theme.palette.brandAccent)
                    .frame(width: 7, height: 7)
                    .padding(5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? LiquidGlassTokens.brandAccent.opacity(0.9)
                            : Color.black.opacity(0.08),
                        lineWidth: isActive ? 1.6 : 1))
            .frame(width: 64, height: 40)
            .accessibilityHidden(true)
    }

    // 常駐頂部右上：對齊 Codex app（#50/#51）＝乾淨圖示列，左＝資訊卡、右＝瀏覽器/檔案。
    // 無文字標籤、無重背景、無四周光暈（#38/#45）；紫只在 active 時上 icon（#38 紫不集中在按鈕）。
    /// Top-right control row on the traffic-light baseline (2026-09-02 使用者):
    /// 左列常駐鈕 ／ 資訊卡（Codex 摘要切換符號）／ 工具箱。三顆同色同尺寸、無框。
    /// 頂列三顆鈕共用的字形。SF Symbol 各自的字面高度與線條粗細不同（sidebar.left 粗、checklist 細且扁），
    /// 所以每顆各自校正字級與字重，讓三顆看起來等高、等粗、同色；顏色統一用 secondary。
    func controlStripGlyph(_ systemName: String) -> some View {
        let tuning: (size: CGFloat, weight: Font.Weight) = switch systemName {
        case "checklist.unchecked": (15, .semibold)
        case "sidebar.left": (13.5, .regular)
        default: (14, .medium)
        }
        return Image(systemName: systemName)
            .font(.system(size: tuning.size, weight: tuning.weight))
            .foregroundStyle(Color.secondary)
            .frame(width: 30, height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    func rightPanelControlStrip(showsThreadControls: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { sidebarPinnedPref.toggle() }
            } label: {
                controlStripGlyph("sidebar.left")
            }
            .buttonStyle(.plain)
            .help(sidebarPinnedPref ? "取消左列常駐" : "左列常駐展示")

            if showsThreadControls {
            // 資訊卡（icon-only）。點擊開/關「懸浮浮層」，不進右側面板（使用者 2026-07-12）。
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) { infoCardFloatingOpen.toggle() }
            } label: {
                controlStripGlyph("checklist.unchecked")
            }
            .buttonStyle(.plain)
            .help("資訊卡")

            // 工具箱：變更收據、瀏覽器、檔案（收進 Menu）。
            let browserFileActive = (rightPanelContent == .browser || rightPanelContent == .file || rightPanelContent == .diff) && isRightPanelOpen
            Menu {
                Button { applyRightPanelInteraction(.toggleDiff) } label: {
                    Label("變更收據 (diff)", systemImage: "doc.text.magnifyingglass")
                }
                Divider()
                Button { applyRightPanelInteraction(.toggleBrowser) } label: {
                    Label("瀏覽器", systemImage: "globe")
                }
                Button { applyRightPanelInteraction(.toggleFile) } label: {
                    Label("檔案", systemImage: "folder")
                }
            } label: {
                controlStripGlyph("case")
                    .accessibilityLabel(browserFileActive ? "工具箱（已開啟面板）" : "工具箱")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("工具箱：變更收據／瀏覽器／檔案")
            }
        }
    }

    func applyRightPanelInteraction(_ action: ChatRightPanelInteractionAction) {
        if action == .toggleBrowser {
            // 瀏覽器走原生 inspector（Plan 同款），不再進右側 overlay。
            browserInspectorPresented.toggle()
            return
        }
        let nextState = ChatRightPanelInteractionPolicy.reduce(
            currentContent: rightPanelContent,
            isPanelOpen: isRightPanelOpen,
            action: action
        )
        if nextState.content != .loops || nextState.preference == false {
            loopsWorkspaceFocused = false
        }
        rightPanelContent = nextState.content
        rightPanelPreference = nextState.preference
    }

    func browserPanelResizeHandle(
        panelWidth: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
                Color.secondary.opacity(
                    isBrowserPanelResizeHandleHovered ? 1 : 0.88))
            .frame(
                width: BrowserPanelOverlayLayoutPolicy.handleSize,
                height: BrowserPanelOverlayLayoutPolicy.handleSize)
            .background(
                LiquidGlassTokens.tint.opacity(
                    isBrowserPanelResizeHandleHovered ? 0.15 : 0.09),
                in: Circle())
            .overlay(
                Circle().strokeBorder(
                    Color.white.opacity(
                        isBrowserPanelResizeHandleHovered ? 0.38 : 0.22),
                    lineWidth: 0.7))
            .shadow(
                color: Color.black.opacity(
                    isBrowserPanelResizeHandleHovered ? 0.14 : 0.08),
                radius: isBrowserPanelResizeHandleHovered ? 5 : 3,
                y: 1)
            .contentShape(Circle())
            .onHover { hovering in
                guard hovering != isBrowserPanelResizeHandleHovered else {
                    return
                }
                isBrowserPanelResizeHandleHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating(
                        $browserPanelDragTranslation
                    ) { value, state, transaction in
                        transaction.animation = nil
                        state = value.translation.width
                    }
                    .updating(
                        $browserPanelResizeActive
                    ) { _, state, transaction in
                        transaction.animation = nil
                        state = true
                    }
                    .onEnded { value in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            browserPanelWidth = Double(
                                BrowserPanelDragPolicy.previewWidth(
                                    persistedWidth:
                                        CGFloat(browserPanelWidth),
                                    translation:
                                        value.translation.width,
                                    windowWidth: windowWidth))
                        }
                    })
            .animation(
                .easeOut(duration: 0.14),
                value: isBrowserPanelResizeHandleHovered)
            .onDisappear {
                if isBrowserPanelResizeHandleHovered {
                    NSCursor.pop()
                    isBrowserPanelResizeHandleHovered = false
                }
            }
            .accessibilityElement()
            .accessibilityLabel("調整瀏覽器面板寬度")
            .accessibilityValue("\(Int(panelWidth)) 點")
            .accessibilityIdentifier("browser-panel-resize-handle")
            .help("拖曳調整瀏覽器面板寬度")
    }

    func browserPanelOverlay(
        panelWidth: CGFloat,
        panelHeight: CGFloat,
        windowWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            rightPanelPane
        }
        // Live resize: the content owns the preview width every drag frame.
        // Extend the panel into the full-size titlebar inset so its top edge is
        // flush with the app window. EmbeddedBrowserView protects the entire
        // toolbar with a non-window-dragging AppKit host, preserving + / tabs /
        // extension / gear hit testing inside this otherwise draggable band.
        .frame(
            width: panelWidth,
            height:
                panelHeight
                + BrowserPanelOverlayLayoutPolicy.windowTopExtension,
            alignment: .topLeading)
        .offset(
            y: -BrowserPanelOverlayLayoutPolicy.windowTopExtension)
        .transaction { transaction in
            if browserPanelResizeActive {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .overlay(alignment: .bottomLeading) {
            browserPanelResizeHandle(
                panelWidth: panelWidth,
                windowWidth: windowWidth)
                .offset(
                    x:
                        BrowserPanelOverlayLayoutPolicy
                            .handleOffset.width,
                    y:
                        BrowserPanelOverlayLayoutPolicy
                            .handleOffset.height)
                .zIndex(90)
        }
        .accessibilityIdentifier("browser-panel-overlay")
    }

    func rightPanelTakeoverHeader(
        presentation: ChatRightPanelPresentation
    ) -> some View {
        let isFocusedWorkspace = presentation == .focusedTakeover
        return HStack(spacing: 8) {
            Button {
                if isFocusedWorkspace {
                    loopsWorkspaceFocused = false
                } else {
                    rightPanelPreference = false
                    isRightPanelOpen = false
                }
            } label: {
                Label(
                    isFocusedWorkspace ? "回到並排" : "返回 Chat",
                    systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(LiquidGlassTokens.brandAccent)
            .accessibilityLabel(
                isFocusedWorkspace
                    ? "縮回 Loops 工作區並回到並排顯示"
                    : "關閉側邊工作區並返回 Chat")

            Spacer(minLength: 4)

            Text(isFocusedWorkspace ? "Loops 全寬工作區" : "側邊工作區")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // 舊的文字版右側面板按鈕 helper 與模式 chip 已被上方 icon-only strip 取代並移除死碼（使用者：不要沒意義代碼；#50/#51 對齊 Codex 圖示列）。

    var rightPanelPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 控制按鈕在常駐頂部 rightPanelControlStrip。資訊卡已改懸浮浮層，右側面板只承載 browser/file 重內容。
            Group {
                switch rightPanelContent {
                case .none:
                    EmptyView()
                case .browser:
                    EmbeddedBrowserView(
                        sessionID: model.selectedThreadID?.uuidString.lowercased(),
                        model: model,
                        isPanelResizing: browserPanelResizeActive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        // Keep the glass modifier mounted so the CEF subtree
                        // retains identity. During live resize, place an
                        // opaque panel-colored layer immediately behind the
                        // content (and in front of the material) to mask
                        // asynchronous material redraw without remounting CEF.
                        .background {
                            RoundedRectangle(
                                cornerRadius: LiquidGlassTokens.radiusCard,
                                style: .continuous)
                                .fill(
                                    Color(nsColor: .windowBackgroundColor))
                                .opacity(
                                    browserPanelResizeActive ? 1 : 0)
                        }
                        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                case .file:
                    ProjectFileBrowserView(
                        rootPath: model.currentConversationWorkspaceURL().path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                case .loops:
                    LoopsSessionRail(
                        sessions: model.selectedThreadLoopsSessions,
                        archivedSessions: model.selectedThreadArchivedLoopsSessions,
                        supervisorModelID: model.selectedThreadSupervisorModelID,
                        selectedID: model.selectedLoopsSessionID,
                        liveRows: model.loopsLiveRows,
                        onCreate: { model.createLoopsSessionForSelectedThread() },
                        onSelect: { model.selectLoopsSession($0) },
                        onArchive: { model.archiveLoopsSession($0) },
                        onRestore: { model.restoreLoopsSession($0) },
                        onSendMessage: { id, text in
                            model.appendHumanLoopNote(id, text: text)
                        },
                        onDispatchSub: { model.dispatchLoopSub($0) },
                        onAdvanceRound: { model.advanceLoopRound($0) },
                        dispatchingID: model.dispatchingLoopID,
                        plgRun: model.activePLGRun,
                        plgDispatchRecords:
                            model.selectedDispatchRuntimeProjection.canonicalRecords,
                        canonicalGoalRecord: model.selectedGoalRecord,
                        plgBlockerMessage: model.plgError,
                        plgPaused: model.plgPaused,
                        isFocusedWorkspace: loopsWorkspaceFocused,
                        onToggleFocus: {
                            withAnimation(
                                .spring(response: 0.24, dampingFraction: 0.88)
                            ) {
                                loopsWorkspaceFocused.toggle()
                            }
                        },
                        onPLGAuthorize: { model.authorizePLG() },
                        onPLGMainline: { model.evaluatePLGMainline($0) },
                        onPLGRollback: { model.rollbackPLG() },
                        onPLGConfirmPlan: {
                            model.confirmPLGPlanAndStartLoops()
                        },
                        onPLGEndGoal: { model.endPLGRun() },
                        onPLGTogglePause: { model.togglePLGPause() },
                        plgCanAdvanceCycle: model.canAdvanceNativeDevelopmentCycle,
                        onPLGAdvanceCycle: { _ = model.advanceNativeDevelopmentCycle() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .diff:
                    DiffReviewView(
                        diffProvider: { model.loadWorkspaceDiff() },
                        goalLabel: model.activeGoalObjectiveLabel.isEmpty ? nil : String(model.activeGoalObjectiveLabel.prefix(12)),
                        reviewerLabel: model.selectedThread?.loopsConfig?.secondaryModelID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread side panel")
        .confirmationDialog(
            "封存這個聊天的 issue list？",
            isPresented: Binding(
                get: { model.pendingArchiveIssuePrompt != nil },
                set: { if !$0 { model.pendingArchiveIssuePrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("保留到全域（不動 issue）") {
                model.resolveArchiveIssuePrompt(keepIssues: true)
            }
            Button("一起封存") {
                model.resolveArchiveIssuePrompt(keepIssues: false)
            }
            Button("取消", role: .cancel) {
                model.pendingArchiveIssuePrompt = nil
            }
        } message: {
            if let p = model.pendingArchiveIssuePrompt {
                Text("「\(p.title)」還有 \(p.count) 筆等待中的 issue。保留＝之後仍可在全域／@ 搜到；一起封存＝移到設定→Issue List→封存的 issue 管理。兩者都不會刪除原討論。")
            }
        }
    }

    var threadInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.shouldShowActiveGoalInlineCard {
                threadPlanSection
            } else {
                threadSummarySection
            }
            if model.gitChangedFileCount > 0 {
                threadOutputFilesCard(files: model.gitChangedFilePreview, total: model.gitChangedFileCount)
            }
            if !model.activeSubagentRows.isEmpty {
                threadSubagentsCard(rows: model.activeSubagentRows)
            }
            threadInfoContextStrip(
                "來源",
                systemImage: model.isSelectedThreadStandalone ? "bubble.left" : "folder",
                tint: .secondary,
                items: threadSourceItems)
            if let project = model.selectedThreadProject {
                threadGitHubRepoSection(project)
            }
            threadPluginSummaryStrip(selected: model.selectedThreadPluginEntries)
            issueListSection
        }
        .padding(11)
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
        .overlay(alignment: .leading) {
            if threadInfoPluginsExpanded {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                LiquidGlassTokens.accentPink,
                                LiquidGlassTokens.accentViolet,
                                LiquidGlassTokens.accentBlue
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(LiquidGlassTokens.tintOpacity)
                    .frame(width: 3, height: 86)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// hover 進出帶 300ms 緩衝：滑進預覽視窗本身也算停留，避免移動途中閃關。
    func issueHoverChanged(_ id: String, inside: Bool) {
        issueHoverCloseTask?.cancel()
        if inside {
            hoveredIssueID = id
        } else {
            issueHoverCloseTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                if hoveredIssueID == id { hoveredIssueID = nil }
            }
        }
    }

    var issueListSection: some View {
        IssueQueueCard(model: model)   // 2.0：問題清單重設計（New/IssueQueueCard.swift），使用者 2026-09-05
    }

    func issueListRow(_ entry: TatwoIssueListEntryV1) -> some View {
        let isExpanded = expandedIssueIDs.contains(entry.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.status == .queued
                        ? Color.secondary.opacity(0.5)
                        : Color.green.opacity(0.8))
                    .frame(width: 5, height: 5)
                Text(entry.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .onHover { issueHoverChanged(entry.id, inside: $0) }
                    .popover(
                        isPresented: Binding(
                            get: { hoveredIssueID == entry.id },
                            set: { if !$0, hoveredIssueID == entry.id { hoveredIssueID = nil } }
                        ),
                        arrowEdge: .leading
                    ) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title)
                                .font(.system(size: 12, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("來源：\(entry.sourceType == .plan ? "Plan" : "Chat")・\(entry.sourceReference)・\(entry.status == .queued ? "等待中" : "已啟用")")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(entry.body)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(30)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if !model.issueImageURLs(for: entry).isEmpty {
                                HStack(spacing: 5) {
                                    ForEach(model.issueImageURLs(for: entry), id: \.path) { url in
                                        if let image = NSImage(contentsOf: url) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 42, height: 42)
                                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        }
                                    }
                                }
                            }
                            issuePackIntoChatButton(entry)
                        }
                        .padding(10)
                        .frame(width: 300, alignment: .topLeading)
                        .onHover { issueHoverChanged(entry.id, inside: $0) }
                    }
                Spacer(minLength: 6)
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.archiveIssueListEntry(entry.id) }
                    .onTapGesture(count: 1) {}
                    .help("封存此 issue（需雙擊；不會刪除原討論）")
                    .accessibilityLabel("封存 issue：\(entry.title)")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    expandedIssueIDs.remove(entry.id)
                } else {
                    expandedIssueIDs.insert(entry.id)
                    model.importLegacyIssueImages(entry)
                }
            }
            if isExpanded {
                // 展開即可編輯內文：先快速入列、之後補細節（改動後出現「儲存」）。
                TextEditor(text: Binding(
                    get: { issueBodyDrafts[entry.id] ?? entry.body },
                    set: { issueBodyDrafts[entry.id] = $0 }
                ))
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 48, maxHeight: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                HStack(spacing: 8) {
                    Text("來源：\(entry.sourceType == .plan ? "Plan" : "Chat")・\(entry.sourceReference)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if let draft = issueBodyDrafts[entry.id], draft != entry.body {
                        Button("儲存") {
                            model.updateIssueListEntryBody(entry.id, body: draft)
                            issueBodyDrafts[entry.id] = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .semibold))
                    }
                }
                HStack(spacing: 6) {
                    ForEach(entry.imageAssetPaths, id: \.self) { relativePath in
                        if let url = model.issueImageURL(relativeAssetPath: relativePath) {
                            ChatLoadedImageAttachment(
                                attachment: .init(path: url.path, name: IssueImageAssets.displayName(url.lastPathComponent)),
                                gallery: model.issueImageURLs(for: entry).map { .init(path: $0.path, name: nil) },
                                size: 64,
                                remove: { model.removeIssueImageNote(relativePath, from: entry) })
                        } else {
                            Label("圖片已遺失", systemImage: "photo.badge.exclamationmark")
                                .font(.caption)
                        }
                    }
                    Button {
                        model.addImageNotes(to: entry)
                    } label: {
                        Label("附加圖片…", systemImage: "photo.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("附加圖片備註；圖片會複製進 Tatwo 附件庫")
                }
            }
        }
    }

    func issuePackIntoChatButton(_ entry: TatwoIssueListEntryV1) -> some View {
        Button {
            model.packIssueIntoComposer(entry)
            issueHoverChanged(entry.id, inside: false)
        } label: {
            Label("帶入聊天", systemImage: "arrow.down.left.and.arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help("只把 issue 帶入輸入框；仍要由你按送出才執行")
    }

    func threadGitHubRepoSection(_ project: TatwoNativeChatProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                Text("GitHub 倉庫")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                if project.githubRepos.count > 1 {
                    Text("\(project.githubRepos.count)")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !project.githubRepos.isEmpty {
                    Button {
                        presentGitHubRepoEditor(for: project)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("編輯 GitHub 倉庫（可多個、標註登入帳號）")
                }
            }

            if githubRepoEditingProjectID == project.id {
                GitHubRepoBindingEditorView(
                    bindings: project.githubRepos,
                    onSave: { bindings in
                        model.setGitHubRepoBindings(bindings, for: project.id)
                        withAnimation(.easeInOut(duration: 0.15)) { githubRepoEditingProjectID = nil }
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.15)) { githubRepoEditingProjectID = nil }
                    })
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white.opacity(ChatUILayout.quietFillOpacity),
                    in: RoundedRectangle(
                        cornerRadius: ChatUILayout.nestedRadius,
                        style: .continuous))
            } else if !project.githubRepos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(project.githubRepos, id: \.url) { binding in
                        VStack(alignment: .leading, spacing: 5) {
                            Button {
                                openGitHubRepoURL(binding.url)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(binding.url)
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.primary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("在瀏覽器開啟 \(binding.url)")

                            HStack(spacing: 6) {
                                githubRepoBadge(
                                    systemImage: "person.crop.circle",
                                    text: binding.accountLabel,
                                    tint: LiquidGlassTokens.brandAccent)
                                githubRepoVisibilityBadge(binding.visibility)
                                if binding.hasUpdate {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                            .shadow(color: Color.green.opacity(0.75), radius: 4)
                                        Text("原始碼有更新")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.green)
                                    }
                                    .accessibilityLabel("GitHub 專案原始碼有新提交")
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            model.checkGitHubRepoUpdates(for: project.id)
                        } label: {
                            HStack(spacing: 6) {
                                if model.isCheckingGitHubRepo(for: project.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(model.isCheckingGitHubRepo(for: project.id) ? "檢查中…" : "檢查原始碼")
                            }
                            .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isCheckingGitHubRepo(for: project.id))
                        .help("只檢查 GitHub 專案原始碼，不是 Tatwo Ultrawork App 更新")
                        Spacer(minLength: 0)
                    }

                    if let message = model.gitHubRepoCheckMessage(for: project.id) {
                        Text(message)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                message.hasPrefix("無法")
                                    ? Color.orange
                                    : (project.githubRepos.contains { $0.hasUpdate } ? Color.green : Color.secondary))
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white.opacity(ChatUILayout.quietFillOpacity),
                    in: RoundedRectangle(
                        cornerRadius: ChatUILayout.nestedRadius,
                        style: .continuous))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ChatUILayout.nestedRadius,
                        style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(ChatUILayout.quietStrokeOpacity),
                        lineWidth: 1)
                }
            } else {
                Button {
                    presentGitHubRepoEditor(for: project)
                } label: {
                    Label("綁定 GitHub 倉庫", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(
                    Color.white.opacity(ChatUILayout.quietFillOpacity),
                    in: RoundedRectangle(
                        cornerRadius: ChatUILayout.nestedRadius,
                        style: .continuous))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ChatUILayout.nestedRadius,
                        style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(ChatUILayout.quietStrokeOpacity),
                        lineWidth: 1)
                }
            }
        }
    }

    func githubRepoBadge(
        systemImage: String,
        text: String,
        tint: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 21)
            .background(tint.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    func githubRepoVisibilityBadge(
        _ visibility: TatwoGitHubRepoBinding.Visibility
    ) -> some View {
        switch visibility {
        case .pub:
            githubRepoBadge(systemImage: "globe", text: "公開", tint: .green)
        case .priv:
            githubRepoBadge(systemImage: "lock.fill", text: "私有", tint: .orange)
        case .unknown:
            githubRepoBadge(systemImage: "questionmark.circle", text: "未知", tint: .secondary)
        }
    }

    /// Editing happens inline in the info card: a sheet attached to the right
    /// pane never showed while the floating card was open (2026-09-02 使用者).
    func presentGitHubRepoEditor(for project: TatwoNativeChatProject) {
        withAnimation(.easeInOut(duration: 0.15)) {
            githubRepoEditingProjectID = project.id
        }
    }

    func openGitHubRepoURL(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return }
        NSWorkspace.shared.open(url)
    }

    var threadSourceItems: [(String, String, String)] {
        if model.isSelectedThreadStandalone {
            return [
                ("Chat", "一般聊天", "bubble.left"),
                ("Thread", compactThreadLabel(model.selectedThread?.id), "number")
            ]
        }
        return [
            ("Project", compactProjectLabel(model.selectedProjectName), "folder"),
            ("Branch", compactBranchLabel(model.gitBranch), "arrow.branch"),
            ("Thread", compactThreadLabel(model.selectedThread?.id), "number")
        ]
    }

    var threadSummarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Thread")
                    .font(.headline.weight(.black))
                Spacer(minLength: 0)
                Text(model.routeChoice.title)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.055), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedThread?.title ?? "未命名 thread")
                    .font(.caption.weight(.black))
                    .lineLimit(2)
                Text(model.selectedThread?.lastPreview.isEmpty == false ? model.selectedThread?.lastPreview ?? "" : "單模型 chat · 尚未建立 GoalRun")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(ChatUILayout.quietFillOpacity), in: RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous).strokeBorder(Color.white.opacity(ChatUILayout.quietStrokeOpacity), lineWidth: 1))

            HStack(spacing: 6) {
                let route = model.routeChoice
                let suffix = modelMenuSecondaryLabel(route).map { " · \($0)" } ?? ""
                chip(systemImage: route.engine.symbol, text: "\(compactRouteLabel(route))\(suffix)")
                chip(systemImage: "puzzlepiece.extension", text: model.selectedThreadPluginSummary)
                Spacer(minLength: 0)
            }
        }
        .help("日常 chat 不自動建立目標；只有送出帶協作/Work OS 的 chat request 才會出現 GoalRun。")
    }

    var threadPlanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Plan")
                    .font(.headline.weight(.black))
                Spacer(minLength: 0)
                Text(model.selectedWorkOSGoalStatusLabel)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.055), in: Capsule())
            }

            Label(model.activeGoalHeaderProgressLabel, systemImage: "checkmark.seal")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatGlassChip(isSelected: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedThread?.title ?? "未命名 thread")
                    .font(.caption.weight(.black))
                    .lineLimit(2)
                Text(model.selectedThread?.lastPreview.isEmpty == false ? model.selectedThread?.lastPreview ?? "" : model.activeWorkOSLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(ChatUILayout.quietFillOpacity), in: RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous).strokeBorder(Color.white.opacity(ChatUILayout.quietStrokeOpacity), lineWidth: 1))
        }
    }

}
