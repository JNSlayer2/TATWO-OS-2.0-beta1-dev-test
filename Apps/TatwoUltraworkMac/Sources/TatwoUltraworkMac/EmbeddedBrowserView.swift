import AppKit
import SwiftUI
import TatwoCEFBridge
import TatwoUltraworkCore
import WebKit
import Darwin

struct EmbeddedBrowserView: View {
    let sessionID: String?
    private let isUIFixture: Bool
    private let isPanelResizing: Bool

    @ObservedObject private var model: ChatPageModel
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @State private var addressText = ""
    @State private var command: EmbeddedBrowserCommand?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var validationMessage: String?
    @State private var currentURLString: String = ""
    @State private var navigationState =
        EmbeddedBrowserNavigationState.blank
    @State private var showAnnotations = false
    @State private var unboundProfileID = UUID()
    @State private var visibleProfileKey: UUID
    @State private var profileAccessState: EmbeddedBrowserProfileAccessState
    @State private var profileAccessRevision = 0
    @State private var profileMaintenanceMessage: String?
    @State private var pendingMaintenanceConfirmation:
        EmbeddedBrowserSessionDisposition?
    @State private var showFinalDeleteConfirmation = false
    @State private var laneState: TatwoBrowserLaneState
    @State private var laneURLs: [TatwoBrowserLaneID: URL]
    @State private var isBrowserRuntimeVisible = false
    @State private var showBrowserManagement = false
    @State private var showBrowserExtensions = false
    @State private var browserExtensionFixtures =
        EmbeddedBrowserExtensionFixture.items
    @State private var showExtensionLoadUnsupported = false
    @State private var bookmarkRailInteraction =
        EmbeddedBrowserBookmarkRailInteractionState()
    @State private var bookmarkRailCollapseTask: Task<Void, Never>?
    @State private var bookmarkContextMenuID: UUID?
    @State private var lastRemovedBookmark: EmbeddedBrowserBookmark?
    @StateObject private var annotationStore: EmbeddedBrowserAnnotationStore
    @StateObject private var bookmarkStore: EmbeddedBrowserBookmarkStore
    @FocusState private var startPageFieldFocused: Bool

    init(
        sessionID: String?,
        model: ChatPageModel,
        isPanelResizing: Bool = false
    ) {
        self.sessionID = sessionID
        self.isPanelResizing = isPanelResizing
        _model = ObservedObject(wrappedValue: model)
        let isUIFixture = EmbeddedBrowserUIFixturePolicy.isEnabled()
        self.isUIFixture = isUIFixture
        _annotationStore = StateObject(
            wrappedValue:
                isUIFixture
                ? EmbeddedBrowserAnnotationStore(
                    fileURL: URL(fileURLWithPath: "/dev/null"))
                : EmbeddedBrowserAnnotationStore.shared)
        let profileKey =
            sessionID.flatMap(TatwoBrowserProfileIdentity.init(sessionID:))?
                .dataStoreIdentifier
            ?? UUID()
        _unboundProfileID = State(initialValue: profileKey)
        _visibleProfileKey = State(initialValue: profileKey)
        _profileAccessState = State(
            initialValue: .checking(profileKey: profileKey))

        let fixtureDate = Date(timeIntervalSince1970: 1_788_192_000)
        let fixtureBookmarks =
            EmbeddedBrowserUIFixturePolicy.bookmarks(
                profileKey: profileKey)
        _bookmarkStore = StateObject(
            wrappedValue:
                isUIFixture
                ? EmbeddedBrowserBookmarkStore(
                    fileURL: nil,
                    seedBookmarks: fixtureBookmarks)
                : EmbeddedBrowserBookmarkStore.shared)
        var lanes = TatwoBrowserLaneState()
        if isUIFixture {
            lanes = TatwoBrowserLaneReducer.reduce(
                state: lanes,
                action: .open(
                    id: TatwoBrowserLaneID(rawValue: "fixture-pinned"),
                    binding: .unboundReadOnly,
                    title: "文件"),
                now: fixtureDate)
            lanes = TatwoBrowserLaneReducer.reduce(
                state: lanes,
                action: .pin(
                    TatwoBrowserLaneID(rawValue: "fixture-pinned"),
                    true),
                now: fixtureDate)
            lanes = TatwoBrowserLaneReducer.reduce(
                state: lanes,
                action: .open(
                    id: TatwoBrowserLaneID(rawValue: "fixture-research"),
                    binding: .unboundReadOnly,
                    title: "研究"),
                now: fixtureDate.addingTimeInterval(1))
            lanes = TatwoBrowserLaneReducer.reduce(
                state: lanes,
                action: .open(
                    id: TatwoBrowserLaneID(rawValue: "fixture-new-tab"),
                    binding: .unboundReadOnly,
                    title: "新分頁"),
                now: fixtureDate.addingTimeInterval(2))
            _laneURLs = State(initialValue: [
                TatwoBrowserLaneID(rawValue: "fixture-pinned"):
                    URL(string: "https://www.google.com/search?q=Tatwo")!,
                TatwoBrowserLaneID(rawValue: "fixture-research"):
                    URL(string: "https://example.com/research")!,
            ])
        } else {
            lanes = TatwoBrowserLaneReducer.reduce(
                state: lanes,
                action: .open(
                    id: TatwoBrowserLaneID(
                        rawValue: "browser-\(UUID().uuidString.lowercased())"),
                    binding: .unboundReadOnly,
                    title: "新分頁"),
                now: Date())
            _laneURLs = State(initialValue: [:])
        }
        _laneState = State(initialValue: lanes)
    }

    private var pageAnnotations: [EmbeddedBrowserAnnotation] {
        annotationStore.annotations(
            forURL: currentURLString,
            profileKey: browserProfile.registryKey)
    }

    private var profileBookmarks: [EmbeddedBrowserBookmark] {
        bookmarkStore.bookmarks(profileKey: browserProfile.registryKey)
    }

    private var selectedBookmarkForContextMenu:
        EmbeddedBrowserBookmark?
    {
        guard let bookmarkContextMenuID else { return nil }
        return profileBookmarks.first {
            $0.id == bookmarkContextMenuID
        }
    }

    private var browserProfile: EmbeddedBrowserRuntimeProfile {
        if let identity = sessionID.flatMap(TatwoBrowserProfileIdentity.init(sessionID:)) {
            return .persistent(identity.dataStoreIdentifier)
        }
        return .ephemeral(unboundProfileID)
    }

    private var browserEngine: EmbeddedBrowserEngine {
        EmbeddedBrowserEnginePolicy.current
    }

    private var selectedLaneURL: URL? {
        guard let selectedLaneID = laneState.selectedLaneID else {
            return nil
        }
        return laneURLs[selectedLaneID]
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar

            Divider()
                .overlay(Color.white.opacity(0.08))

            if showAnnotations, !pageAnnotations.isEmpty {
                annotationList
                Divider().overlay(Color.white.opacity(0.08))
            }

            if isBrowserRuntimeVisible {
                browserSurface
                    .id(
                        EmbeddedChromiumBrowserMountIdentity(
                            profile: browserProfile))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                browserStartPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("內嵌瀏覽器")
        .onDisappear {
            model.clearBrowserAgentActivePage(sessionID: sessionID)
        }
        .task(
            id:
                "\(browserEngine.rawValue):\(browserProfile.registryKey.uuidString):\(profileAccessRevision):\(isBrowserRuntimeVisible)"
        ) {
            guard
                isBrowserRuntimeVisible,
                EmbeddedBrowserUIFixturePolicy.allowsRealActions(
                    isFixture: isUIFixture)
            else {
                return
            }
            await refreshProfileAccess()
        }
        .confirmationDialog(
            pendingMaintenanceConfirmation == .delete
                ? "刪除此瀏覽器 Session？"
                : "重設此瀏覽器 Session？",
            isPresented: Binding(
                get: { pendingMaintenanceConfirmation != nil },
                set: {
                    if !$0 {
                        pendingMaintenanceConfirmation = nil
                    }
                }),
            titleVisibility: .visible
        ) {
            if pendingMaintenanceConfirmation == .delete {
                Button("繼續", role: .destructive) {
                    pendingMaintenanceConfirmation = nil
                    showFinalDeleteConfirmation = true
                }
            } else {
                Button("確認重設", role: .destructive) {
                    pendingMaintenanceConfirmation = nil
                    resetBrowserSession()
                }
            }
            Button("取消", role: .cancel) {
                pendingMaintenanceConfirmation = nil
            }
        } message: {
            Text(
                pendingMaintenanceConfirmation == .delete
                    ? "只刪除瀏覽器 Session 資料，不刪除 Chat 對話；下一步仍會再次確認。"
                    : "Cookie、登入狀態、網站儲存與瀏覽記錄會清除；Chat 對話不受影響。")
        }
        .confirmationDialog(
            "再次確認刪除瀏覽器 Session？",
            isPresented: $showFinalDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("刪除瀏覽資料", role: .destructive) {
                showFinalDeleteConfirmation = false
                deleteBrowserSession()
            }
            Button("取消", role: .cancel) {
                showFinalDeleteConfirmation = false
            }
        } message: {
            Text(
                "CEF profile 會移到系統垃圾桶；WebKit 資料由系統清除，無法從垃圾桶還原。Chat 對話不會被刪除。")
        }
    }

    @ViewBuilder
    private var browserSurface: some View {
        if isUIFixture {
            fixtureBrowserSurface
        } else {
            ZStack {
                browserRuntime
                if let failureMessage =
                    EmbeddedBrowserRuntimeFailurePresentation
                        .startupFailureMessage(
                            engine: browserEngine,
                            currentURLString: currentURLString,
                            phase: navigationState.phase,
                            visibleError: validationMessage.map {
                                .runtimeMessage($0)
                            })
                {
                    browserUnavailablePlaceholder(
                        title: "Chromium failed to start",
                        detail: failureMessage,
                        retry: {
                            profileAccessRevision &+= 1
                        })
                        .background(.regularMaterial)
                        .accessibilityIdentifier(
                            "embedded-browser-runtime-failure")
                } else {
                    browserStateOverlay
                }
            }
        }
    }

    private var fixtureBrowserSurface: some View {
        ZStack {
            LiquidGlassTokens.canvasBackground
                .opacity(0.54)
            VStack(spacing: 10) {
                Image(systemName: "safari")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                Text(
                    selectedLaneURL?.host
                        ?? URL(string: currentURLString)?.host
                        ?? "Fixture browser")
                    .font(.system(size: 14, weight: .semibold))
                Text("Fixture browsing surface")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("browser-fixture-browsing-surface")
    }

    @ViewBuilder
    private var browserStateOverlay: some View {
        switch EmbeddedBrowserSurfacePresentation.condition(
            for: navigationState)
        {
        case .none:
            EmptyView()
        case .pageCreating:
            VStack {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("頁面建立中，尚未提交導覽…")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityIdentifier("embedded-browser-page-creating")
        case .loadedAwaitingPaint:
            browserStateCard(
                title: "頁面已載入，等待首次繪製",
                detail:
                    "主框架已提交，但目前尚未收到可顯示畫面。",
                systemImage: "rectangle.inset.filled.and.person.filled",
                color: .secondary)
                .allowsHitTesting(false)
                .accessibilityIdentifier(
                    "embedded-browser-awaiting-first-paint")
        case let .blockedBySecurity(message):
            browserStateCard(
                title:
                    EmbeddedBrowserSecurityStatusPresentation
                        .title(for: message),
                detail: message,
                systemImage: "exclamationmark.shield.fill",
                color: .orange)
                .accessibilityIdentifier(
                    "embedded-browser-security-block")
        case let .navigationFailure(message, code):
            browserStateCard(
                title: "Page navigation failed",
                detail: diagnosticDetail(message: message, code: code),
                systemImage: "wifi.exclamationmark",
                color: .red,
                retry: { issue(.reload) })
                .accessibilityIdentifier(
                    "embedded-browser-navigation-failure")
        case let .subprocessRestart(message, code):
            browserStateCard(
                title: "瀏覽器子程序異常重啟",
                detail: diagnosticDetail(message: message, code: code),
                systemImage: "exclamationmark.triangle.fill",
                color: .red,
                retry: { issue(.reload) })
                .accessibilityIdentifier(
                    "embedded-browser-subprocess-restart")
        case let .httpFailure(status):
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "network.badge.shield.half.filled")
                    Text("HTTP \(status)")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityIdentifier("embedded-browser-http-status")
        case .blankNoncommitted:
            browserStateCard(
                title: "Waiting for first committed page",
                detail:
                    "Chromium 已掛載，但主框架尚未提交可顯示網址。",
                systemImage: "rectangle.dashed",
                color: .secondary)
                .allowsHitTesting(false)
                .accessibilityIdentifier(
                    "embedded-browser-blank-noncommitted")
        }
    }

    private func browserStateCard(
        title: String,
        detail: String,
        systemImage: String,
        color: Color,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diagnosticDetail(
        message: String,
        code: Int?
    ) -> String {
        guard let code else { return message }
        return "\(message)（code \(code)）"
    }

    @ViewBuilder
    private var browserRuntime: some View {
        let profileKey = browserProfile.registryKey
        if let initialURL = selectedLaneURL,
           EmbeddedBrowserRuntimeMountPolicy.allowsMount(
            state: profileAccessState,
            profileKey: profileKey)
        {
            switch browserEngine {
            case .chromiumCEF:
                EmbeddedChromiumBrowserView(
                    profile: browserProfile,
                    tabID: laneState.selectedLaneID?.rawValue
                        ?? "browser-unbound",
                    initialURL: initialURL,
                    command: command,
                    isGeometryDragInProgress: isPanelResizing,
                    onNavigationStateChange: applyNavigationState)
            case .chromiumUnavailable:
                browserUnavailablePlaceholder(
                    title: "Chromium runtime unavailable",
                    detail: "The required Chromium runtime is not available.")
            case .webKitLegacy:
                EmbeddedBrowserWebView(
                    profile: browserProfile,
                    initialURL: initialURL,
                    command: command,
                    annotationStore: annotationStore,
                    onNavigationStateChange: applyNavigationState)
            }
        } else {
            switch profileAccessState {
            case .checking:
                browserUnavailablePlaceholder(
                    title: "Checking browser profile",
                    detail:
                        "Lifecycle recovery, capacity, and profile access are checked before the browser runtime is created.")
            case let .blocked(_, failure):
                browserUnavailablePlaceholder(
                    title: "Browser profile blocked",
                    detail: failure.visibleMessage,
                    retry: {
                        profileAccessRevision &+= 1
                    })
            case .ready:
                browserUnavailablePlaceholder(
                    title: "Checking browser profile",
                    detail: "The selected session changed; access is being revalidated.")
            }
        }
    }

    private func browserUnavailablePlaceholder(
        title: String,
        detail: String,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let retry {
                Button("Retry formal recovery check", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshProfileAccess() async {
        let profile = browserProfile
        let profileKey = profile.registryKey
        if visibleProfileKey != profileKey {
            clearSessionDerivedVisibleState()
            visibleProfileKey = profileKey
        } else {
            command = nil
            validationMessage = nil
            navigationState = .blank
        }
        if browserEngine == .chromiumUnavailable {
            clearActivePageVisibleState()
        }
        profileAccessState = .checking(profileKey: profileKey)
        guard profile.dataStoreIdentifier != nil else {
            profileAccessState = .ready(profileKey: profileKey)
            return
        }
        let result = await EmbeddedBrowserProfileAccessCoordinator.live
            .recordAccessAndEnforce(
                profile: profile,
                engine: browserEngine)
        guard !Task.isCancelled,
              browserProfile.registryKey == profileKey
        else {
            return
        }
        switch result {
        case .success:
            profileAccessState = .ready(profileKey: profileKey)
        case let .failure(error):
            profileAccessState = .blocked(
                profileKey: profileKey,
                failure: error)
        }
    }

    private func clearSessionDerivedVisibleState() {
        // SwiftUI may preserve this view's @State while its session/profile
        // input changes. Clear every visible value derived from the previous
        // profile before access validation or runtime mount begins.
        clearActivePageVisibleState()
        command = nil
        validationMessage = nil
        navigationState = .blank
        profileMaintenanceMessage = nil
    }

    private func clearActivePageVisibleState() {
        model.clearBrowserAgentActivePage(sessionID: sessionID)
        addressText = ""
        currentURLString = ""
        canGoBack = false
        canGoForward = false
        showAnnotations = false
    }

    private var browserStartPage: some View {
        ZStack {
            LiquidGlassTokens.canvasBackground
                .opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 18) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(
                            "搜尋或輸入網址",
                            text: $addressText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .focused($startPageFieldFocused)
                            .onSubmit(loadAddress)
                            .accessibilityIdentifier(
                                "browser-start-page-search-field")
                    }

                    HStack {
                        Spacer(minLength: 0)
                        startPageSubmitButton
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(
                    maxWidth:
                        EmbeddedBrowserBookmarkRailLayoutPolicy
                        .searchCardMaximumWidth)
                .liquidGlassSurface(
                    cornerRadius: LiquidGlassTokens.radiusCard)

                GeometryReader { geometry in
                    bookmarkRail(
                        cardContentWidth: geometry.size.width)
                }
                .frame(
                    maxWidth:
                        EmbeddedBrowserBookmarkRailLayoutPolicy
                        .searchCardMaximumWidth,
                    minHeight:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth
                        + EmbeddedBrowserBookmarkRailHoverPolicy
                        .verticalPadding * 2,
                    maxHeight:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth
                        + EmbeddedBrowserBookmarkRailHoverPolicy
                        .verticalPadding * 2,
                    alignment: .leading)
                .accessibilityIdentifier(
                    "browser-bookmark-rail-outside-search-card")
            }
            .frame(
                maxWidth:
                    EmbeddedBrowserBookmarkRailLayoutPolicy
                    .searchCardMaximumWidth,
                alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                    if let bookmark = selectedBookmarkForContextMenu {
                        bookmarkContextMenu(bookmark)
                            .offset(x: 58, y: 42)
                            .transition(
                                .opacity.combined(
                                    with: .scale(
                                        scale: 0.94,
                                        anchor: .topLeading)))
                            .zIndex(40)
                    }
                }
            .overlay(alignment: .bottom) {
                    if let bookmark = lastRemovedBookmark {
                        HStack(spacing: 8) {
                            Text("已移除 \(bookmark.displayTitle)")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                            Button("還原", action: undoLastBookmarkRemoval)
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(
                                    LiquidGlassTokens.brandAccent)
                                .accessibilityIdentifier(
                                    "browser-bookmark-undo")
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                Color.white.opacity(0.22),
                                lineWidth: 0.7))
                        .offset(y: 46)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            .padding(.horizontal, 22)
            .offset(y: -22)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            bookmarkContextMenuID = nil
            collapseBookmarkRailFromOutside()
            startPageFieldFocused = true
        }
        .onExitCommand(perform: collapseBookmarkRailFromOutside)
        .accessibilityIdentifier("browser-native-start-page")
    }

    private var startPageSubmitButton: some View {
        Button(action: loadAddress) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(
                    addressText
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        .isEmpty
                        ? Color.secondary
                        : Color.white)
                .frame(width: 30, height: 30)
                .background(
                    addressText
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        .isEmpty
                        ? LiquidGlassTokens.tint.opacity(
                            LiquidGlassTokens.chipFillOpacity)
                        : LiquidGlassTokens.brandAccent,
                    in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(
            addressText
                .trimmingCharacters(
                    in: .whitespacesAndNewlines)
                .isEmpty)
        .accessibilityLabel("搜尋或前往")
        .accessibilityIdentifier("browser-start-page-submit")
    }

    private func bookmarkRail(
        cardContentWidth: CGFloat
    ) -> some View {
        let hoverRegion = EmbeddedBrowserBookmarkRailHoverPolicy.hoverRegion(
            isExpanded: bookmarkRailInteraction.isExpanded,
            bookmarkCount: profileBookmarks.count,
            cardContentWidth: cardContentWidth)
        return ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(
                    spacing:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleSpacing)
                {
                    bookmarkRailAnchor
                    if bookmarkRailInteraction.isExpanded {
                        addBookmarkBubble
                        ForEach(profileBookmarks) { bookmark in
                            bookmarkBubble(bookmark)
                        }
                    }
                }
            }
                .frame(
                    width: hoverRegion.width,
                    height:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth,
                    alignment: .leading)
        }
        .frame(
            width: hoverRegion.width,
            height: hoverRegion.height,
            alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                bookmarkRailPointerEntered()
            case .ended:
                bookmarkRailPointerExited()
            }
        }
        .onDisappear(perform: cancelBookmarkRailCollapse)
        .zIndex(bookmarkContextMenuID == nil ? 0 : 20)
        .accessibilityIdentifier("browser-bookmark-rail")
    }

    private var bookmarkRailAnchor: some View {
        Button(action: toggleBookmarkRailPinnedOpen) {
            Image(systemName: "bookmark.fill")
                .font(
                    .system(
                        size:
                            EmbeddedBrowserBookmarkRailLayoutPolicy
                            .anchorSymbolSize,
                        weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.94))
                .frame(
                    width:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth,
                    height:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth)
                .background {
                    Circle()
                        .fill(
                            LiquidGlassTokens.tint.opacity(
                                bookmarkRailNeutralFillOpacity))
                        .frame(
                            width:
                                EmbeddedBrowserBookmarkRailLayoutPolicy
                                .anchorVisualSize,
                            height:
                                EmbeddedBrowserBookmarkRailLayoutPolicy
                                .anchorVisualSize)
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(
                                    bookmarkRailInteraction.isPointerInside
                                        || bookmarkRailInteraction
                                        .isClickExpanded
                                        ? 0.34
                                        : 0.22),
                                lineWidth: 0.6))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("書籤")
        .accessibilityIdentifier("browser-bookmark-anchor")
    }

    private var addBookmarkBubble: some View {
        Button(action: addCurrentPageBookmark) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(
                    width:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth,
                    height:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth)
                .background(
                    LiquidGlassTokens.tint.opacity(
                        bookmarkRailNeutralFillOpacity),
                    in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(currentURLString.isEmpty)
        .foregroundStyle(
            currentURLString.isEmpty
                ? Color.secondary.opacity(0.45)
                : Color.secondary.opacity(0.94))
        .help(
            currentURLString.isEmpty
                ? "目前分頁沒有可加入的網址"
                : "加入目前分頁")
        .accessibilityLabel("加入目前分頁書籤")
        .accessibilityIdentifier("browser-bookmark-add")
    }

    private func bookmarkBubble(
        _ bookmark: EmbeddedBrowserBookmark
    ) -> some View {
        Button {
            openBookmark(bookmark)
        } label: {
            bookmarkFavicon(bookmark)
                .frame(
                    width:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth,
                    height:
                        EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth)
                .background(
                    LiquidGlassTokens.tint.opacity(
                        bookmarkContextMenuID == bookmark.id
                            ? 0.14
                            : bookmarkRailNeutralFillOpacity),
                    in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        bookmarkContextMenuID == bookmark.id
                            ? Color.white.opacity(0.44)
                            : Color.white.opacity(0.18),
                        lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .help(bookmark.tooltip)
        .accessibilityLabel(bookmark.tooltip)
        .accessibilityIdentifier(
            "browser-bookmark-\(bookmark.id.uuidString.lowercased())")
        .overlay {
            EmbeddedBrowserSecondaryClickSurface {
                withAnimation(
                    .spring(response: 0.22, dampingFraction: 0.86))
                {
                    bookmarkContextMenuID = bookmark.id
                }
            }
        }
        .zIndex(bookmarkContextMenuID == bookmark.id ? 30 : 0)
    }

    @ViewBuilder
    private func bookmarkFavicon(
        _ bookmark: EmbeddedBrowserBookmark
    ) -> some View {
        AsyncImage(url: bookmark.faviconURL) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
                    .padding(6)
                    .saturation(0)
                    .opacity(0.84)
            } else {
                Text(bookmark.initial)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bookmarkContextMenu(
        _ bookmark: EmbeddedBrowserBookmark
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(role: .destructive) {
                removeBookmark(bookmark)
            } label: {
                Label("移除書籤", systemImage: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("browser-bookmark-remove")
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                Color.white.opacity(0.24),
                lineWidth: 0.7))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        .onHover { hovering in
            guard !hovering else { return }
            withAnimation(
                .spring(response: 0.22, dampingFraction: 0.86))
            {
                bookmarkContextMenuID = nil
                bookmarkRailInteraction.collapseIfAllowed(
                    isContextMenuVisible: false)
            }
        }
        .accessibilityIdentifier("browser-bookmark-custom-menu")
    }

    private var browserToolbar: some View {
        HStack(
            alignment: .center,
            spacing: 0
        ) {
            browserTabStrip
            browserNewTabButton
            Spacer(
                minLength:
                    EmbeddedBrowserToolbarLayoutPolicy
                    .toolbarControlSpacing)
            browserTrailingControls
        }
        .frame(
            height: EmbeddedBrowserToolbarLayoutPolicy.rowHeight,
            alignment: .center)
        .padding(.horizontal, 8)
        .padding(
            .vertical,
            EmbeddedBrowserToolbarLayoutPolicy.toolbarVerticalPadding)
        // The panel intentionally extends into the full-size titlebar band to
        // sit flush with the window top. This AppKit backing view opts the
        // complete toolbar out of window dragging so + / tabs / extension /
        // gear receive their mouse-down events.
        .background(NonWindowDraggingView())
        .accessibilityIdentifier("browser-toolbar")
    }

    private var browserTrailingControls: some View {
        HStack(
            alignment: .center,
            spacing:
                EmbeddedBrowserToolbarLayoutPolicy
                .trailingControlSpacing
        ) {
            Button {
                showBrowserExtensions.toggle()
            } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(
                        width:
                            EmbeddedBrowserToolbarLayoutPolicy
                            .controlHitTarget,
                        height:
                            EmbeddedBrowserToolbarLayoutPolicy
                            .controlHitTarget,
                        alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                showBrowserExtensions
                    ? Color.primary
                    : Color.secondary)
            .help("擴充功能")
            .accessibilityLabel("擴充功能")
            .accessibilityIdentifier("browser-extensions-button")
            .popover(isPresented: $showBrowserExtensions) {
                browserExtensionsPopover
                    .padding(18)
                    .frame(width: 390)
            }

            Button {
                showBrowserManagement.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(
                        width:
                            EmbeddedBrowserToolbarLayoutPolicy
                            .controlHitTarget,
                        height:
                            EmbeddedBrowserToolbarLayoutPolicy
                            .controlHitTarget,
                        alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                showBrowserManagement
                    ? Color.primary
                    : Color.secondary)
            .help("瀏覽器設定")
            .accessibilityLabel("瀏覽器設定")
            .accessibilityIdentifier("browser-settings-button")
            .popover(isPresented: $showBrowserManagement) {
                TatwoBrowserManagementView(
                    model: model,
                    provider: browserManagementProvider,
                    onClose: { showBrowserManagement = false })
                    .padding(18)
                    .frame(width: 540, height: 470)
            }
        }
        .frame(
            height: EmbeddedBrowserToolbarLayoutPolicy.rowHeight,
            alignment: .center)
        .accessibilityIdentifier("browser-toolbar-trailing-controls")
    }

    private var browserExtensionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("擴充功能")
                    .font(.title3.bold())
                Text("這裡先整理常用的瀏覽器功能；實際載入 Chrome 擴充功能會在後續版本接上。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 7) {
                ForEach($browserExtensionFixtures) { $extensionFixture in
                    Toggle(isOn: $extensionFixture.isEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(extensionFixture.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(extensionFixture.purpose)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(10)
                    .background(
                        Color.secondary.opacity(0.055),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous))
                    .accessibilityIdentifier(
                        "browser-extension-\(extensionFixture.id)")
                }
            }

            Divider()

            Button(action: chooseUnpackedExtensionDirectory) {
                Label(
                    "載入已解壓縮的擴充功能…",
                    systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(
                "browser-extension-load-unpacked")
        }
        .alert(
            "此版本尚未支援載入",
            isPresented: $showExtensionLoadUnsupported
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text("已選取資料夾，但本輪只完成介面，尚未連接 Chromium 擴充功能載入。")
        }
        .accessibilityIdentifier("browser-extensions-popover")
    }

    private func chooseUnpackedExtensionDirectory() {
        let panel = NSOpenPanel()
        panel.title = "選擇已解壓縮的擴充功能資料夾"
        panel.prompt = "選擇"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard TatwoModalPanelGate.run({ panel.runModal() }) == .OK else {
            return
        }
        showExtensionLoadUnsupported = true
    }

    private var browserTabStrip: some View {
        // Keep one stable new-tab Button outside both the adaptive container
        // and the horizontal ScrollView. Duplicating the interactive control
        // across ViewThatFits alternatives makes its pointer target swap with
        // the selected layout even though the glyph remains visible.
        HStack(
            alignment: .center,
            spacing: EmbeddedBrowserToolbarLayoutPolicy.tabSpacing
        ) {
            browserTabStripTabs
        }
        .frame(
            height: EmbeddedBrowserToolbarLayoutPolicy.rowHeight,
            alignment: .center)
        .layoutPriority(1)
        .accessibilityIdentifier("browser-tab-strip")
    }

    private var browserTabStripTabs: some View {
        // Plain HStack of pills — no ViewThatFits / ScrollView. ViewThatFits
        // renders every candidate to measure it, which left the new-tab
        // button's pointer target misaligned from its glyph. Pills shrink
        // (title lineLimit) when crowded instead of scrolling.
        browserTabPills
            .frame(maxHeight: .infinity, alignment: .center)
    }

    private var browserTabPills: some View {
        HStack(
            alignment: .center,
            spacing: EmbeddedBrowserToolbarLayoutPolicy.tabSpacing
        ) {
            ForEach(laneState.lanes) { lane in
                browserTab(lane)
            }
        }
        .frame(
            height: EmbeddedBrowserToolbarLayoutPolicy.rowHeight,
            alignment: .center)
    }

    private var browserNewTabButton: some View {
        // Mirror the trailing control buttons (extension/gear) exactly, which
        // fire reliably. Extra outer .frame/.contentShape wrappers previously
        // swallowed the tap before it reached the Button action.
        Button(action: openNewTab) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(
                    width:
                        EmbeddedBrowserToolbarLayoutPolicy
                        .controlHitTarget,
                    height:
                        EmbeddedBrowserToolbarLayoutPolicy
                        .controlHitTarget,
                    alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .help("新分頁")
        .accessibilityIdentifier("browser-new-tab")
    }

    private func browserTab(_ lane: TatwoBrowserLane) -> some View {
        let isSelected = lane.id == laneState.selectedLaneID
        return HStack(
            spacing:
                EmbeddedBrowserToolbarLayoutPolicy
                .tabTitleCloseSpacing
        ) {
            Button {
                selectLane(lane.id)
            } label: {
                HStack(
                    spacing:
                        EmbeddedBrowserToolbarLayoutPolicy
                        .tabContentSpacing
                ) {
                    if lane.isPinned {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        Text(browserTabInitial(for: lane))
                            .font(.system(size: 9, weight: .bold))
                            .frame(
                                width:
                                    EmbeddedBrowserToolbarLayoutPolicy
                                    .tabFaviconSize,
                                height:
                                    EmbeddedBrowserToolbarLayoutPolicy
                                    .tabFaviconSize,
                                alignment: .center)
                            .background(
                                Color.secondary.opacity(
                                    isSelected ? 0.18 : 0.10),
                                in: Circle())
                        Text(browserTabTitle(for: lane))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .frame(
                    maxWidth: lane.isPinned ? 22 : 116,
                    minHeight:
                        EmbeddedBrowserToolbarLayoutPolicy.tabHeight,
                    alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier(
                "browser-tab-select-\(lane.id.rawValue)")

            if !lane.isPinned {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(
                        width:
                            EmbeddedBrowserToolbarLayoutPolicy
                            .tabCloseHitTarget,
                        height:
                            EmbeddedBrowserToolbarLayoutPolicy
                            .tabCloseHitTarget,
                        alignment: .center)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded {
                        closeLane(lane.id)
                    })
                    .accessibilityElement()
                    .accessibilityLabel("關閉分頁")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        closeLane(lane.id)
                    }
                    .accessibilityIdentifier(
                        "browser-tab-close-\(lane.id.rawValue)")
                    .foregroundStyle(.secondary)
                    .help("關閉分頁")
            }
        }
        .padding(
            .horizontal,
            EmbeddedBrowserToolbarLayoutPolicy.tabHorizontalPadding)
        .frame(
            height: EmbeddedBrowserToolbarLayoutPolicy.tabHeight,
            alignment: .center)
        .foregroundStyle(
            isSelected
                ? Color.primary.opacity(0.92)
                : Color.secondary.opacity(0.86))
        .background(
            isSelected
                ? Color.primary.opacity(0.07)
                : Color.clear,
            in: RoundedRectangle(
                cornerRadius: LiquidGlassTokens.radiusChip,
                style: LiquidGlassTokens.shapeStyle))
        .contentShape(
            RoundedRectangle(
                cornerRadius: LiquidGlassTokens.radiusChip,
                style: LiquidGlassTokens.shapeStyle))
        .contextMenu {
            Button {
                togglePinned(lane.id, isPinned: !lane.isPinned)
            } label: {
                Label(
                    lane.isPinned ? "取消釘選" : "釘選",
                    systemImage: lane.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                closeLane(lane.id)
            } label: {
                Label("關閉分頁", systemImage: "xmark")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            lane.isPinned
                ? "已釘選分頁 \(browserTabTitle(for: lane))"
                : "分頁 \(browserTabTitle(for: lane))")
        .accessibilityIdentifier("browser-tab-\(lane.id.rawValue)")
    }

    private func browserTabTitle(for lane: TatwoBrowserLane) -> String {
        guard let host = laneURLs[lane.id]?.host, !host.isEmpty else {
            return lane.title
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func browserTabInitial(for lane: TatwoBrowserLane) -> String {
        String(browserTabTitle(for: lane).prefix(1)).uppercased()
    }

    private func addCurrentPageBookmark() {
        guard !currentURLString.isEmpty,
              let selectedLane = laneState.selectedLane,
              let candidate = EmbeddedBrowserBookmarkPolicy.candidate(
                urlString: currentURLString,
                title: browserTabTitle(for: selectedLane),
                profileKey: browserProfile.registryKey)
        else {
            return
        }
        if bookmarkStore.add(candidate) {
            lastRemovedBookmark = nil
        }
    }

    private func openBookmark(_ bookmark: EmbeddedBrowserBookmark) {
        guard let url = bookmark.resolvedURL else { return }
        bookmarkContextMenuID = nil
        if isUIFixture {
            guard let selectedLaneID = laneState.selectedLaneID else {
                return
            }
            laneURLs[selectedLaneID] = url
            addressText = url.absoluteString
            currentURLString = url.absoluteString
            navigationState = EmbeddedBrowserNavigationState(
                urlString: url.absoluteString,
                canGoBack: false,
                canGoForward: false,
                visibleError: nil,
                phase: .finished,
                committedMainFrameURLString: url.absoluteString)
            isBrowserRuntimeVisible = true
            return
        }
        navigate(to: url)
    }

    private func removeBookmark(_ bookmark: EmbeddedBrowserBookmark) {
        guard let removed = bookmarkStore.remove(id: bookmark.id) else {
            return
        }
        bookmarkContextMenuID = nil
        withAnimation(
            .spring(response: 0.24, dampingFraction: 0.86))
        {
            lastRemovedBookmark = removed
        }
    }

    private func undoLastBookmarkRemoval() {
        guard let bookmark = lastRemovedBookmark,
              bookmarkStore.restore(bookmark)
        else {
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            lastRemovedBookmark = nil
        }
    }

    private var bookmarkRailNeutralFillOpacity: Double {
        bookmarkRailInteraction.isPointerInside
            || bookmarkRailInteraction.isClickExpanded
            ? 0.11
            : LiquidGlassTokens.chipFillOpacity
    }

    private func toggleBookmarkRailPinnedOpen() {
        cancelBookmarkRailCollapse()
        withAnimation(
            .spring(response: 0.26, dampingFraction: 0.82))
        {
            bookmarkRailInteraction.toggleClick()
        }
    }

    private func bookmarkRailPointerEntered() {
        cancelBookmarkRailCollapse()
        withAnimation(
            .spring(response: 0.26, dampingFraction: 0.82))
        {
            bookmarkRailInteraction.pointerEntered()
        }
    }

    private func bookmarkRailPointerExited() {
        bookmarkRailInteraction.pointerExited()
        scheduleBookmarkRailCollapse()
    }

    private func scheduleBookmarkRailCollapse() {
        cancelBookmarkRailCollapse()
        bookmarkRailCollapseTask = Task { @MainActor in
            try? await Task.sleep(
                for: EmbeddedBrowserBookmarkRailHoverPolicy.collapseDelay)
            guard !Task.isCancelled else {
                return
            }
            withAnimation(
                .spring(response: 0.26, dampingFraction: 0.82))
            {
                bookmarkRailInteraction.collapseIfAllowed(
                    isContextMenuVisible: bookmarkContextMenuID != nil)
            }
            bookmarkRailCollapseTask = nil
        }
    }

    private func cancelBookmarkRailCollapse() {
        bookmarkRailCollapseTask?.cancel()
        bookmarkRailCollapseTask = nil
    }

    private func collapseBookmarkRailFromOutside() {
        cancelBookmarkRailCollapse()
        withAnimation(
            .spring(response: 0.24, dampingFraction: 0.84))
        {
            bookmarkRailInteraction.collapseFromOutside()
        }
    }

    private var browserManagementProvider:
        any TatwoBrowserManagementProviding
    {
        isUIFixture
            ? TatwoBrowserManagementFixtureProvider()
            : TatwoBrowserManagementProviderFactory.make()
    }

    private var annotationList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pageAnnotations) { annotation in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 9))
                            .foregroundStyle(LiquidGlassTokens.brandAccent)
                        Text(annotation.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            annotationStore.remove(annotation)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("刪除此註解")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Color.white.opacity(ChatUILayout.quietFillOpacity),
                        in: RoundedRectangle(cornerRadius: ChatUILayout.microRadius, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(maxHeight: 140)
    }

    private func browserButton(
        systemImage: String,
        help: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .disabled(!isEnabled)
        .help(help)
    }

    private func openNewTab() {
        let id = TatwoBrowserLaneID(
            rawValue: "browser-\(UUID().uuidString.lowercased())")
        let next = EmbeddedBrowserNewTabAction.perform(
            state: laneState,
            id: id,
            now: Date())
        guard next != laneState else { return }
        laneState = next
        command = nil
        validationMessage = nil
        navigationState = .blank
        isBrowserRuntimeVisible = false
        clearActivePageVisibleState()
    }

    private func selectLane(_ id: TatwoBrowserLaneID) {
        guard laneState.selectedLaneID != id else { return }
        laneState = TatwoBrowserLaneReducer.reduce(
            state: laneState,
            action: .select(id),
            now: Date())

        guard EmbeddedBrowserUIFixturePolicy.allowsRealActions(
            isFixture: isUIFixture)
        else {
            command = nil
            validationMessage = nil
            navigationState = .blank
            isBrowserRuntimeVisible = false
            clearActivePageVisibleState()
            return
        }

        guard let url = laneURLs[id] else {
            command = nil
            validationMessage = nil
            navigationState = .blank
            isBrowserRuntimeVisible = false
            clearActivePageVisibleState()
            return
        }

        addressText = url.absoluteString
        currentURLString = url.absoluteString
        validationMessage = nil
        if isBrowserRuntimeVisible,
           profileAccessState.isReady(for: browserProfile.registryKey)
        {
            issue(.load(url))
        } else {
            command = nil
            navigationState = .blank
            isBrowserRuntimeVisible = true
        }
    }

    private func closeLane(_ id: TatwoBrowserLaneID) {
        let closedSelectedLane = laneState.selectedLaneID == id
        laneURLs[id] = nil
        laneState = TatwoBrowserLaneReducer.reduce(
            state: laneState,
            action: .close(id),
            now: Date())

        if laneState.lanes.isEmpty {
            openNewTab()
            return
        }
        guard closedSelectedLane, let selectedLaneID = laneState.selectedLaneID
        else {
            return
        }

        guard EmbeddedBrowserUIFixturePolicy.allowsRealActions(
            isFixture: isUIFixture)
        else {
            command = nil
            navigationState = .blank
            isBrowserRuntimeVisible = false
            clearActivePageVisibleState()
            return
        }

        if let url = laneURLs[selectedLaneID] {
            addressText = url.absoluteString
            currentURLString = url.absoluteString
            if isBrowserRuntimeVisible,
               profileAccessState.isReady(for: browserProfile.registryKey)
            {
                issue(.load(url))
            } else {
                command = nil
                navigationState = .blank
                isBrowserRuntimeVisible = true
            }
        } else {
            command = nil
            navigationState = .blank
            isBrowserRuntimeVisible = false
            clearActivePageVisibleState()
        }
    }

    private func togglePinned(
        _ id: TatwoBrowserLaneID,
        isPinned: Bool
    ) {
        laneState = TatwoBrowserLaneReducer.reduce(
            state: laneState,
            action: .pin(id, isPinned),
            now: Date())
    }

    private func navigate(to url: URL) {
        guard let selectedLaneID = laneState.selectedLaneID else { return }
        laneURLs[selectedLaneID] = url
        validationMessage = nil
        addressText = url.absoluteString
        currentURLString = url.absoluteString

        if isBrowserRuntimeVisible,
           profileAccessState.isReady(for: browserProfile.registryKey)
        {
            issue(.load(url))
        } else {
            command = nil
            navigationState = .blank
            isBrowserRuntimeVisible = true
        }
    }

    private func loadAddress() {
        guard EmbeddedBrowserUIFixturePolicy.allowsRealActions(
            isFixture: isUIFixture)
        else {
            return
        }
        switch TatwoBrowserAddressResolver.resolve(addressText) {
        case let .navigate(url):
            switch EmbeddedBrowserNavigationPolicy.decision(for: url) {
            case .allow:
                navigate(to: url)
            case let .block(reason):
                let error = EmbeddedBrowserVisibleError
                    .blockedNavigation(reason)
                validationMessage = error.message
                navigationState = EmbeddedBrowserNavigationState(
                    urlString: currentURLString.isEmpty
                        ? nil
                        : currentURLString,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    visibleError: error,
                    phase: .blockedBySecurity,
                    committedMainFrameURLString:
                        currentURLString.isEmpty
                            ? nil
                            : currentURLString,
                    structuredError:
                        EmbeddedBrowserNavigationError(
                            kind: .security,
                            code: nil,
                            message: error.message))
            }
        case .reject(.emptyInput):
            validationMessage = "請輸入搜尋內容或完整網址"
        case .reject(.malformedHTTPURL):
            validationMessage = "HTTP(S) 網址格式不正確"
        case .reject(.unsupportedScheme):
            validationMessage = "安全限制：僅允許 http 或 https"
        }
    }

    private func issue(_ action: EmbeddedBrowserCommand.Action) {
        guard EmbeddedBrowserUIFixturePolicy.allowsRealActions(
            isFixture: isUIFixture)
        else {
            return
        }
        guard EmbeddedBrowserCommandDispatchPolicy.dispatch(
            action,
            state: profileAccessState,
            profileKey: browserProfile.registryKey,
            sink: { command = EmbeddedBrowserCommand(action: $0) })
        else {
            validationMessage =
                "Browser profile 尚未 ready，命令已 fail-closed。"
            return
        }
        model.clearBrowserAgentActivePage(sessionID: sessionID)
    }

    private func clearCurrentSiteData() {
        guard let sessionID,
              let originURL = URL(string: currentURLString),
              profileAccessState.isReady(for: browserProfile.registryKey)
        else {
            profileMaintenanceMessage =
                EmbeddedBrowserSiteDataMaintenanceError.invalidOrigin
                    .visibleMessage
            return
        }
        let profileKey = browserProfile.registryKey
        let engine = browserEngine
        profileAccessState = .checking(profileKey: profileKey)
        command = nil
        profileMaintenanceMessage = "正在關閉 runtime 並執行單站資料清除…"
        Task { @MainActor in
            await waitForRuntimeLeaseRelease(
                profileKey: profileKey,
                engine: engine)
            let result = await EmbeddedBrowserSiteDataMaintenanceCoordinator()
                .clear(
                    originURL: originURL,
                    sessionID: sessionID,
                    engine: engine)
            guard browserProfile.registryKey == profileKey else { return }
            switch result {
            case let .success(outcome):
                profileMaintenanceMessage = outcome.visibleMessage
            case let .failure(error):
                profileMaintenanceMessage = error.visibleMessage
            }
            profileAccessRevision &+= 1
        }
    }

    private func resetBrowserSession() {
        guard let sessionID,
              profileAccessState.isReady(for: browserProfile.registryKey)
        else {
            profileMaintenanceMessage =
                EmbeddedBrowserSessionLifecycleError
                .invalidSessionID.visibleMessage
            return
        }
        let profileKey = browserProfile.registryKey
        let engine = browserEngine
        profileAccessState = .checking(profileKey: profileKey)
        command = nil
        profileMaintenanceMessage = "正在關閉 runtime 並重設瀏覽器 Session…"
        Task { @MainActor in
            await waitForRuntimeLeaseRelease(
                profileKey: profileKey,
                engine: engine)
            let transaction = EmbeddedBrowserSessionLifecycleTransaction(
                disposition: .reset,
                sessionID: sessionID)
            let prepared = await transaction.prepare()
            let committed: Result<
                EmbeddedBrowserSessionLifecycleReceipt,
                EmbeddedBrowserSessionLifecycleError
            >
            switch prepared {
            case let .success(receipt):
                committed = transaction.commitProfileOnly(receipt: receipt)
            case let .failure(error):
                committed = .failure(error)
            }
            guard browserProfile.registryKey == profileKey else { return }
            switch committed {
            case .success:
                currentURLString = ""
                addressText = ""
                canGoBack = false
                canGoForward = false
                navigationState = .blank
                if let selectedLaneID = laneState.selectedLaneID {
                    laneURLs[selectedLaneID] = nil
                }
                isBrowserRuntimeVisible = false
                profileMaintenanceMessage =
                    "瀏覽器 Session 已透過 durable lifecycle transaction 重設。"
            case let .failure(error):
                profileMaintenanceMessage = error.visibleMessage
            }
            profileAccessRevision &+= 1
        }
    }

    private func deleteBrowserSession() {
        guard let sessionID,
              profileAccessState.isReady(for: browserProfile.registryKey)
        else {
            profileMaintenanceMessage =
                EmbeddedBrowserSessionLifecycleError
                .invalidSessionID.visibleMessage
            return
        }
        let profileKey = browserProfile.registryKey
        let engine = browserEngine
        profileAccessState = .checking(profileKey: profileKey)
        command = nil
        profileMaintenanceMessage =
            "正在關閉 runtime 並刪除瀏覽器 Session 資料…"
        Task { @MainActor in
            await waitForRuntimeLeaseRelease(
                profileKey: profileKey,
                engine: engine)
            let transaction = EmbeddedBrowserSessionLifecycleTransaction(
                disposition: .delete,
                sessionID: sessionID)
            let committed: Result<
                EmbeddedBrowserSessionLifecycleReceipt,
                EmbeddedBrowserSessionLifecycleError
            >
            switch await transaction.prepare() {
            case let .success(receipt):
                committed = transaction.commitDeletedProfile(
                    receipt: receipt)
            case let .failure(error):
                committed = .failure(error)
            }
            guard browserProfile.registryKey == profileKey else { return }
            switch committed {
            case .success:
                clearSessionDerivedVisibleState()
                laneURLs.removeAll()
                isBrowserRuntimeVisible = false
                profileMaintenanceMessage =
                    "瀏覽器 Session 資料已刪除；Chat 對話未刪除。"
            case let .failure(error):
                profileMaintenanceMessage = error.visibleMessage
            }
            profileAccessRevision &+= 1
        }
    }

    private func waitForRuntimeLeaseRelease(
        profileKey: UUID,
        engine: EmbeddedBrowserEngine
    ) async {
        for _ in 0 ..< 20 {
            let released: Bool
            switch engine {
            case .webKitLegacy:
                released = !EmbeddedBrowserWebViewRegistry.shared
                    .activeProfiles.contains(
                        .persistent(profileKey))
            case .chromiumCEF:
                released = TatwoCEFProfileLeaseRegistry.shared
                    .activeLeaseCount(for: profileKey) == 0
            case .chromiumUnavailable:
                released = true
            }
            if released { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func applyNavigationState(
        _ state: EmbeddedBrowserNavigationState
    ) {
        navigationState = state
        model.updateBrowserAgentActivePage(
            sessionID: sessionID,
            state: state)
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
        validationMessage = state.visibleError?.message
        if EmbeddedBrowserActivePageRetentionPolicy
            .shouldClearActivePage(for: state)
        {
            clearActivePageVisibleState()
        } else if let urlString = state.urlString {
            addressText = urlString
            currentURLString = urlString
            if let selectedLaneID = laneState.selectedLaneID,
               let url = URL(string: urlString)
            {
                laneURLs[selectedLaneID] = url
            }
        }
    }
}
