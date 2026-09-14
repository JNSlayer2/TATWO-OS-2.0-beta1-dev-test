import SwiftUI

/// An activity bar, not a fabricated download percentage. Shared by chat/work space.
struct BrowserNavigationProgress: View {
    let tabID: UUID?
    let state: EmbeddedBrowserNavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    private struct Update: Equatable {
        let tab: UUID?
        let generation: UInt64
        let active: Bool
    }

    private var update: Update {
        Update(tab: tabID, generation: state.navigationGeneration,
               active: tabID != nil && state.showsNavigationProgress)
    }

    var body: some View {
        Rectangle()
            .fill(TatwoActivePalette.current.brandAccent)
            .frame(height: 2)
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .accessibilityIdentifier("browser-navigation-progress")
            .task(id: update) {
                if update.active {
                    visible = true
                } else {
                    // Main-frame load_end is sufficient; no wait on late subresources.
                    // A newer tab/navigation cancels this task and its pending dismissal.
                    do { try await Task.sleep(for: .milliseconds(200)) }
                    catch { return }
                    visible = false
                }
            }
    }
}
