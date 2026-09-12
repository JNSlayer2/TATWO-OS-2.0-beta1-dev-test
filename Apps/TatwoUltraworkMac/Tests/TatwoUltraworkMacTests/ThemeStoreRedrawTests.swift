import AppKit
import SwiftUI
import XCTest

@testable import TatwoUltraworkMac

@MainActor
final class ThemeStoreRedrawTests: XCTestCase {
    func testModesPageUsesLiveThemeObservationAndThemeSwitchRedraws() async throws {
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ModesPage.swift",
            repoRoot: ChatPageSourceScanner.repoRoot()
        )
        XCTAssertTrue(
            source.contains(
                """
                struct ModesPage: View {
                    @ObservedObject private var themeStore = TatwoThemeStore.shared
                """
            )
        )

        let store = TatwoThemeStore.shared
        let originalThemeID = store.activeThemeID
        let targetThemeID: TatwoThemeID =
            originalThemeID == .aurora ? .fable5 : .aurora
        defer { store.select(originalThemeID) }

        let redraw = expectation(description: "observed theme consumer redraws")
        let recorder = ThemeBodyRenderRecorder(targetThemeID: targetThemeID) {
            redraw.fulfill()
        }
        let host = NSHostingView(
            rootView: ThemeObservationRedrawProbe(recorder: recorder)
        )
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(recorder.renderedThemeIDs.contains(originalThemeID))

        store.select(targetThemeID)
        await fulfillment(of: [redraw], timeout: 1.0)

        XCTAssertTrue(recorder.renderedThemeIDs.contains(targetThemeID))
        _ = host
    }
}

@MainActor
private final class ThemeBodyRenderRecorder {
    private let targetThemeID: TatwoThemeID
    private let onTargetTheme: () -> Void
    private(set) var renderedThemeIDs: [TatwoThemeID] = []
    private var didReachTargetTheme = false

    init(targetThemeID: TatwoThemeID, onTargetTheme: @escaping () -> Void) {
        self.targetThemeID = targetThemeID
        self.onTargetTheme = onTargetTheme
    }

    func record(_ themeID: TatwoThemeID) {
        renderedThemeIDs.append(themeID)
        if themeID == targetThemeID, !didReachTargetTheme {
            didReachTargetTheme = true
            onTargetTheme()
        }
    }
}

@MainActor
private struct ThemeObservationRedrawProbe: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let recorder: ThemeBodyRenderRecorder

    var body: some View {
        recorder.record(themeStore.activeThemeID)
        return Color.clear
    }
}
