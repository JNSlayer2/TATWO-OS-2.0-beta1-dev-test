import Foundation
import Combine

/// Settings › Computer Use (approved design v5, 2026-09-11). Background operation and the arrow
/// animation are always on by the user's decision — no switches for them. These are the only knobs.
@MainActor
final class ComputerUseSettings: ObservableObject {
    static let shared = ComputerUseSettings()

    enum ArrowStyle: String, CaseIterable, Identifiable, Sendable {
        case aurora   // 流光＋淺泛光 (G6, the current style)
        case clear    // 清透玻璃 (G1, the lightest)
        case dart     // 黑色尖頭（參考 Codex）
        var id: String { rawValue }
        var title: String {
            switch self {
            case .aurora: "流光＋淺泛光"
            case .clear: "清透玻璃"
            case .dart: "黑色尖頭"
            }
        }
    }

    private enum Key {
        static let enabled = "tatwo.computerUse.enabled"
        static let showArrow = "tatwo.computerUse.showArrow"
        static let showLabel = "tatwo.computerUse.showLabel"
        static let arrowStyle = "tatwo.computerUse.arrowStyle"
    }

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) } }
    @Published var showArrow: Bool {
        didSet { UserDefaults.standard.set(showArrow, forKey: Key.showArrow); ComputerUsePointerOverlay.shared.settingsChanged() }
    }
    @Published var showLabel: Bool {
        didSet { UserDefaults.standard.set(showLabel, forKey: Key.showLabel); ComputerUsePointerOverlay.shared.settingsChanged() }
    }
    @Published var arrowStyle: ArrowStyle {
        didSet { UserDefaults.standard.set(arrowStyle.rawValue, forKey: Key.arrowStyle); ComputerUsePointerOverlay.shared.settingsChanged() }
    }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        showArrow = defaults.object(forKey: Key.showArrow) as? Bool ?? true
        showLabel = defaults.object(forKey: Key.showLabel) as? Bool ?? true
        arrowStyle = ArrowStyle(rawValue: defaults.string(forKey: Key.arrowStyle) ?? "") ?? .aurora
    }

    /// Readable off the main actor (the controller's AX work runs detached); UserDefaults is thread-safe.
    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
}
