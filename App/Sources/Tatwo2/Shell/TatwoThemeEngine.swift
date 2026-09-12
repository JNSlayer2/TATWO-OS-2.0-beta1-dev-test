// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoThemeEngine.swift；改動 1 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
// DEPRECATED REFERENCE — 2026-08-20 Aurora reconnaissance:
// S2 migration did not occur; this engine/tokens path has zero view consumers.
// Retained only as a candidate foundation for a future semantic-token migration.
// Revival or archival remains a user decision.

import SwiftUI

// MARK: - H7 S1 theme engine (architecture only)
//
// Runtime switch surface + SwiftUI environment injection.
// S1 registers **only** `default` (values from `LiquidGlassTokens` live reads).
// Views must continue to read `LiquidGlassTokens` / `ChatTypography` directly until S2 migration.
// Future liquid-glass / commemorative packs register here without becoming a second truth source
// for the default path.

enum TatwoThemeEngineError: Error, Equatable, Sendable {
    /// Unknown or unregistered theme id — fail closed (no silent fallback to default).
    case unknownTheme(String)
}

@MainActor
final class TatwoThemeEngine: ObservableObject {
    static let shared = TatwoThemeEngine()

    /// Registered theme factories. S1: `default` only.
    private static let registeredFactories: [String: () -> TatwoThemeTokensV1] = [
        TatwoThemeEngineID.default.rawValue: { TatwoThemeTokensV1.fromLiquidGlassTokens(themeID: .default) }
    ]

    /// Currently selected theme id (S1 starts at default).
    @Published private(set) var currentThemeID: TatwoThemeEngineID

    /// Last resolved token bag for `currentThemeID`. Rebuilt on successful `setTheme` /
    /// `refreshFromSource`. Default factory always re-reads `LiquidGlassTokens` (single source).
    @Published private(set) var tokens: TatwoThemeTokensV1

    /// Stable list of registered ids (contract for UI / tests).
    var registeredThemeIDs: [TatwoThemeEngineID] {
        Self.registeredFactories.keys
            .sorted()
            .map(TatwoThemeEngineID.init(rawValue:))
    }

    init(initialThemeID: TatwoThemeEngineID = .default) {
        // Fail closed at construction if default were ever unregistered.
        precondition(
            Self.registeredFactories[initialThemeID.rawValue] != nil,
            "TatwoThemeEngine initial theme must be registered"
        )
        self.currentThemeID = initialThemeID
        self.tokens = Self.registeredFactories[initialThemeID.rawValue]!()
    }

    /// Whether `id` is registered for runtime selection.
    func isRegistered(_ id: TatwoThemeEngineID) -> Bool {
        Self.registeredFactories[id.rawValue] != nil
    }

    func isRegistered(rawValue: String) -> Bool {
        Self.registeredFactories[rawValue] != nil
    }

    /// Runtime theme switch. Unknown / unregistered ids throw `unknownTheme` (fail closed).
    func setTheme(_ id: TatwoThemeEngineID) throws {
        try setTheme(rawValue: id.rawValue)
    }

    /// String API used by settings / IPC / tests. Unknown ids fail closed — no default fallback.
    func setTheme(rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let factory = Self.registeredFactories[trimmed]
        else {
            throw TatwoThemeEngineError.unknownTheme(rawValue)
        }
        let id = TatwoThemeEngineID(rawValue: trimmed)
        currentThemeID = id
        tokens = factory()
    }

    /// Re-resolve current theme from its factory (LiquidGlassTokens live read for default).
    func refreshFromSource() {
        guard let factory = Self.registeredFactories[currentThemeID.rawValue] else {
            // Should be unreachable: currentThemeID is only set via setTheme after registry check.
            assertionFailure("current theme unregistered")
            return
        }
        tokens = factory()
    }

    /// Resolve tokens for an id without mutating engine state. Unknown → nil (fail closed).
    func peekTokens(for id: TatwoThemeEngineID) -> TatwoThemeTokensV1? {
        Self.registeredFactories[id.rawValue]?()
    }
}

// MARK: - SwiftUI environment injection points (S1: hung only; views do not read yet)

private struct TatwoThemeTokensEnvironmentKey: EnvironmentKey {
    /// Default environment value mirrors the sole registered theme (LiquidGlassTokens wrap).
    static var defaultValue: TatwoThemeTokensV1 {
        TatwoThemeTokensV1.fromLiquidGlassTokens()
    }
}

private struct TatwoThemeEngineIDEnvironmentKey: EnvironmentKey {
    static let defaultValue: TatwoThemeEngineID = .default
}

extension EnvironmentValues {
    /// Semantic token bag for the active engine theme. S1: views still ignore this key.
    var tatwoThemeTokens: TatwoThemeTokensV1 {
        get { self[TatwoThemeTokensEnvironmentKey.self] }
        set { self[TatwoThemeTokensEnvironmentKey.self] = newValue }
    }

    /// Active engine theme id. S1: hung for future `@Environment(\.tatwoThemeEngineID)` migration.
    var tatwoThemeEngineID: TatwoThemeEngineID {
        get { self[TatwoThemeEngineIDEnvironmentKey.self] }
        set { self[TatwoThemeEngineIDEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Hang S1 theme engine on a root view without changing any visual token reads.
    /// Views continue to use `LiquidGlassTokens` until S2 migrates per surface.
    func tatwoThemeEngineEnvironment(_ engine: TatwoThemeEngine = .shared) -> some View {
        self
            .environmentObject(engine)
            .environment(\.tatwoThemeTokens, engine.tokens)
            .environment(\.tatwoThemeEngineID, engine.currentThemeID)
    }
}
