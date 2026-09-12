import Foundation
import XCTest

final class Round8LiquidGlassUITests: XCTestCase {
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // Round8LiquidGlassUITests.swift -> TatwoUltraworkCoreTests
        url.deleteLastPathComponent() // Tests
        url.deleteLastPathComponent() // TatwoUltraworkCore
        url.deleteLastPathComponent() // Packages
        url.deleteLastPathComponent() // repository root
        return url
    }

    private func read(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func declaration(named name: String, in source: String) -> String {
        guard let range = source.range(of: "struct \(name)") ?? source.range(of: "enum \(name)") else {
            XCTFail("Missing declaration \(name)")
            return ""
        }
        let rest = source[range.lowerBound...]
        if let next = rest.dropFirst().range(of: "\nstruct ") ?? rest.dropFirst().range(of: "\nenum ") ?? rest.dropFirst().range(of: "\nextension ") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    func testLiquidGlassTokensDocumentDashboardTruthAndNativeShaderDowngrade() throws {
        let tokens = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/LiquidGlassTokens.swift")
        let expected = [
            "Dashboard: shape =",
            "Dashboard: radiusPx = 34",
            "Dashboard: glassTint =",
            "Dashboard: layer.alpha = 0.18",
            "Dashboard: blur = 2.2",
            "Dashboard: saturation = 1.0",
            "Dashboard: distortion = 1.25",
            "Dashboard: chromaticAberration = 0.75",
            "Dashboard: shadowIntensity = 0.04",
            "Dashboard: shadowOffsetX = 0.0",
            "Dashboard: shadowOffsetY =",
            "不自造假 shader"
        ]
        for needle in expected {
            XCTAssertTrue(tokens.contains(needle), "LiquidGlassTokens.swift must include source note: \(needle)")
        }
    }

    func testWorkflowReceiptRailIsLightLiquidGlassNotDarkPlate() throws {
        let ultra = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift")
        let rail = declaration(named: "WorkOSPlanLoopsGoalReceiptRail", in: ultra)
        XCTAssertFalse(rail.contains("Color.black.opacity"), "receipt rail must not use a dark/black backing plate")
        // 2026-08-20 極光 P4：tatwoAdaptiveMaterial 為新的共享輕玻璃 token
        //（極光=ultraThinMaterial、fable5=暖紙分支），列入允許樣式。
        XCTAssertTrue(
            rail.contains(".ultraThinMaterial")
                || rail.contains("liquidGlassSurface")
                || rail.contains("tatwoAdaptiveMaterial"),
            "receipt rail should use the shared light liquid-glass material")
        XCTAssertTrue(rail.contains("LiquidGlassTokens"), "receipt rail should consume LiquidGlassTokens")
    }

    func testScenarioPageIsReadOnlyWorkflowPresentation() throws {
        let scenario = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift")
        let page = declaration(named: "ScenariosPage", in: scenario)
        let presentation = declaration(named: "ScenarioWorkflowPresentationCard", in: scenario)

        XCTAssertTrue(page.contains("ScenarioGateSummaryCard"), "scenario page must keep Gate summary presentation")
        XCTAssertTrue(page.contains("ScenarioWorkflowPresentationCard"), "scenario page must keep read-only workflow presentation card")
        XCTAssertTrue(page.contains("ScenarioSavedCanvasVersionsRail"), "scenario page must keep saved canvas versions rail")
        XCTAssertTrue(presentation.contains("WorkOSPlanLoopsGoalCycleMap"), "presentation card must host Plan+Loops+Goal cycle map")
        XCTAssertFalse(scenario.contains("struct ScenarioOSConfigurationBar"), "Wave 1 removes scenario OS configuration CRUD bar")
        XCTAssertFalse(scenario.contains("struct ScenarioWorkflowCanvasCard"), "Wave 1 removes interactive workflow canvas card")
        XCTAssertFalse(scenario.contains("onAddWorkflowNode"), "Wave 1 removes canvas node mutators")
        XCTAssertFalse(scenario.contains("ScenarioHoverInspectorDrawer"), "Wave 1 removes inspector drawer")
        XCTAssertFalse(scenario.contains("ScenarioRightInspectorPanel"), "Wave 1 removes right inspector panel")
    }

    func testRound9ModesPageDefersHeavyGraphAndRasterizesVisibleCanvas() throws {
        let modes = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ModesPage.swift")
        XCTAssertTrue(modes.contains("ModeSwitchSkeleton"), "mode switching should show a lightweight skeleton before mounting heavy graph content")
        XCTAssertTrue(modes.contains("mountHeavyContent"), "mode page should defer expensive graph rendering during page switches")
        XCTAssertTrue(modes.contains(".drawingGroup()"), "mode graph/canvas should be rasterized with drawingGroup()")
        XCTAssertTrue(modes.contains("modePageVisible"), "mode page animations must run only while the page is visible")
        XCTAssertTrue(modes.contains(".onDisappear"), "mode page should stop animation work when hidden")
    }

    func testRound9TraitsUseManualOverlayScoreBarAndGlassOneRatingButton() throws {
        let traits = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TraitsPage.swift")
        let ratingRow = declaration(named: "HumanCollabRatingRow", in: traits)
        let addButton = traits[traits.range(of: "private var addRatingButton")!.lowerBound...]
        XCTAssertTrue(traits.contains("HumanOverlayScoreBar"), "manual ratings should render as a score-bar tail extension or notch, not as a parallel blue badge")
        XCTAssertTrue(addButton.contains("liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)"), "manual rating button must use the shared Glass 1 material")
        XCTAssertTrue(addButton.contains(".frame(height: 23"), "manual rating button should use the Round 9 engineering 22-24pt height")
        XCTAssertFalse(ratingRow.contains("Text(\"人工\")"), "manual rating rows should not keep the old parallel blue 人工 badge")
    }

    func testRound9ScenarioActionButtonsUseLiquidGlassAndNeutralText() throws {
        let scenario = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift")
        let style = declaration(named: "ScenarioLiquidGlassActionButtonStyle", in: scenario)
        XCTAssertTrue(scenario.contains("ScenarioLiquidGlassActionButtonStyle"), "scenario page should still provide shared liquid-glass action button style for leaf rails")
        XCTAssertTrue(style.contains("foregroundStyle(.primary)"), "scenario action text should stay neutral; color belongs to status badges")
        XCTAssertTrue(style.contains("LiquidGlassTokens"), "shared action style must consume LiquidGlassTokens")
    }

    func testQuotaLiveRefreshRunsOffMainActorAndShowsSkeleton() throws {
        let m3 = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoM3PrototypeViews.swift")
        XCTAssertTrue(m3.contains("Task.detached(priority: .utility)"), "live quota refresh must leave the main actor")
        XCTAssertTrue(m3.contains("initialLiveSnapshot ?? .loading") || m3.contains("LiveQuotaDeckSnapshot.loading"), "quota page should render cached/pending state before live data returns")
        XCTAssertTrue(m3.contains("QuotaSkeletonOverlay"), "quota cards need a visible skeleton while pending")
    }

    func testRound11ScenarioWorkflowPresentationIsNonInteractive() throws {
        let scenario = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ScenarioPage.swift")
        let presentation = declaration(named: "ScenarioWorkflowPresentationCard", in: scenario)

        XCTAssertTrue(presentation.contains("WorkOSPlanLoopsGoalCycleMap"), "read-only presentation must still render the cycle map")
        XCTAssertTrue(presentation.contains(".allowsHitTesting(false)"), "workflow map presentation must not capture edit gestures")
        XCTAssertFalse(scenario.contains("struct ScenarioCanvasEventBridge"), "Wave 1 removes canvas pan/zoom event bridge")
        XCTAssertFalse(scenario.contains("struct ScenarioCanvasNonWindowDraggingView"), "Wave 1 removes canvas window-drag shield")
        XCTAssertFalse(scenario.contains("canvasPanGesture"), "Wave 1 removes canvas pan gestures")
        XCTAssertFalse(scenario.contains("activeCanvasTool"), "Wave 1 removes canvas tool state")
    }

    func testRound11ModesPanelDoesNotExportSkeletonOrWarmWarningStrips() throws {
        let modes = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ModesPage.swift")
        let page = declaration(named: "ModesPage", in: modes)
        let skeleton = declaration(named: "ModeSwitchSkeleton", in: modes)
        let summary = declaration(named: "ModeMinimalCurrentHeader", in: modes)

        XCTAssertTrue(page.contains("mountHeavyContent = Self.isSnapshotExport || surface == .panel"), "panel mode page should mount contract content immediately instead of exporting skeleton leftovers")
        XCTAssertTrue(page.contains("if surface == .window"), "skeleton fallback should be window-only")
        XCTAssertFalse(skeleton.contains("RoundedRectangle"), "Round 11 panel must not leave skeleton bar artifacts")
        XCTAssertFalse(summary.contains("case .xl: .orange"), "mode summary should avoid warm XL orange strips in compact panel")
        XCTAssertFalse(modes.contains("WorkOSModeSurfaceStrip(contract: osContract)"), "compact mode summaries should not append the old warm residual horizontal strip")
    }

    func testRound11UltraPanelSummaryUsesNeutralCompactTreatment() throws {
        let ultra = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/UltraPage.swift")
        let summary = declaration(named: "WorkOSPanelFlowSummary", in: ultra)
        let step = declaration(named: "WorkOSPanelFlowStep", in: ultra)
        let routeTile = declaration(named: "WorkOSModeRouteTile", in: ultra)
        let primaryRail = declaration(named: "WorkOSDashboardPrimaryRail", in: ultra)

        XCTAssertFalse(summary.contains(".orange"), "Ultra panel flow summary must not keep warm warning-like orange steps")
        XCTAssertFalse(step.contains("foregroundStyle(color)"), "Ultra panel step labels should read neutral, not like colored warning bars")
        XCTAssertFalse(routeTile.contains("case .xl: .orange"), "Ultra panel route tile should not paint XL as orange in compact summary")
        XCTAssertFalse(primaryRail.contains("Color.orange.opacity"), "dashboard next-action compact card should not leave orange residual warning strip")
    }

    func testShellUsesUnifiedCodexMinimumWindowFloorAcrossPages() throws {
        let shell = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift")
        let metrics = declaration(named: "TatwoAppSurfaceMetrics", in: shell)

        XCTAssertTrue(
            metrics.contains("static let windowMinSize = NSSize(width: 480, height: 600)"),
            "the Work OS window must shrink to the measured Codex minimum viewport"
        )
        XCTAssertTrue(
            metrics.contains("static let compactWindowMinSize = windowMinSize"),
            "compact pages must use the same 480×600 floor"
        )
        XCTAssertTrue(
            metrics.contains("static func minimumWindowSize(for _: TatwoPage) -> NSSize")
                && metrics.contains("\n        windowMinSize\n"),
            "page changes must not raise the minimum window size"
        )
    }

    func testChatInitialStoreLoadIsDeferredOutsideMainActorInit() throws {
        let chat = try ChatPageSourceScanner.combinedSource(
            repoRoot: ChatPageSourceScanner.repoRoot(fromCoreTestFile: #filePath))
        guard let initStart = chat.range(of: "init(environment: [String: String]"),
              let initEnd = chat.range(of: "\n    static let confirmedPlanComputerHostBindingBlocker", range: initStart.upperBound..<chat.endIndex)
        else {
            XCTFail("ChatPageModel initializer boundary not found")
            return
        }
        let initializer = String(chat[initStart.lowerBound..<initEnd.lowerBound])

        XCTAssertFalse(initializer.contains("\n        loadStore()"), "ChatPageModel init must not synchronously load store/bridge data")
        XCTAssertTrue(chat.contains("@Published internal(set) var isLoadingStore = true"), "Chat must expose a lightweight loading state")
        XCTAssertTrue(
            chat.contains("initialStoreLoadController.start(priority: .userInitiated)"),
            "initial store and bridge load must use the cancellable detached controller"
        )
        XCTAssertTrue(
            chat.contains("loadDocumentOverlayFailSoft("),
            "the deferred initial-load path must gate external-volume mirror reads before touching Codex state"
        )
        XCTAssertFalse(
            chat.contains("try? codexAppStateBridge?.loadDocumentOverlay()"),
            "the App must not bypass the fail-soft external-volume gate"
        )
        XCTAssertTrue(
            chat.contains("啟用 Codex thread 鏡射")
                && chat.contains("Codex 鏡射未啟用")
                && chat.contains("Codex 鏡射不可用"),
            "the App must expose an explicit opt-in action and lightweight degraded statuses"
        )
    }

    func testWindowPagesUseLazyOnceRetentionInsteadOfSelectionSwitchTeardown() throws {
        let shell = try read("Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift")
        let panel = declaration(named: "TatwoPanelView", in: shell)

        XCTAssertTrue(panel.contains("@State private var retainedWindowPages"), "window page container must track pages created once")
        XCTAssertTrue(panel.contains("retainedWindowPage(.chat)"), "Chat must remain mounted after first creation")
        XCTAssertTrue(panel.contains(".opacity(selection == page ? 1 : 0)"), "retained pages must switch visibility without teardown")
        XCTAssertTrue(panel.contains(".allowsHitTesting(selection == page)"), "hidden retained pages must not intercept interaction")
    }
}
