import Foundation

enum BrowserAction: String, CaseIterable, Codable, Sendable {
    case newTab, closeTab, reopenClosedTab, back, forward, reload, stopLoading, findInPage
    case zoomIn, zoomOut, zoomReset, focusAddressBar, nextTab, previousTab, tabNumber
    case toggleAnnotations, openDiagnostics, newSpace, openImport, undoBookmarkDeletion, printPage, printPDF

    var requiresTab: Bool {
        switch self {
        case .newTab, .reopenClosedTab, .newSpace, .openImport, .openDiagnostics, .focusAddressBar, .undoBookmarkDeletion: false
        default: true
        }
    }
    var title: String {
        switch self {
        case .newTab: "新分頁"
        case .closeTab: "關閉分頁"
        case .reopenClosedTab: "重新開啟關閉的分頁"
        case .back: "返回"
        case .forward: "前進"
        case .reload: "重新載入"
        case .stopLoading: "停止載入"
        case .findInPage: "頁內搜尋"
        case .zoomIn: "放大"
        case .zoomOut: "縮小"
        case .zoomReset: "重設縮放"
        case .focusAddressBar: "聚焦網址列"
        case .nextTab: "下一個分頁"
        case .previousTab: "上一個分頁"
        case .tabNumber: "切到第 N 個分頁"
        case .toggleAnnotations: "註解"
        case .openDiagnostics: "診斷"
        case .newSpace: "新增 space"
        case .openImport: "從其他瀏覽器導入"
        case .undoBookmarkDeletion: "復原刪除的書籤"
        case .printPage: "列印"
        case .printPDF: "列印備援：存成 PDF 開啟"
        }
    }
    var group: String {
        switch self {
        case .newTab, .closeTab, .reopenClosedTab, .nextTab, .previousTab, .tabNumber: "分頁"
        case .back, .forward, .reload, .stopLoading, .focusAddressBar: "導覽"
        case .findInPage, .zoomIn, .zoomOut, .zoomReset: "檢視"
        case .toggleAnnotations, .openDiagnostics, .newSpace, .openImport, .undoBookmarkDeletion, .printPage, .printPDF: "工具"
        }
    }
}

struct BrowserKeyCombo: Codable, Equatable, Sendable {
    var key: String
    var modifiers: [String]
    var normalized: Self {
        Self(key: key.lowercased(), modifiers: ["control", "option", "shift", "command"].filter { modifiers.contains($0) })
    }
    var display: String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return normalized.modifiers.compactMap { symbols[$0] }.joined()
            + (["escape": "⎋", "tab": "⇥", "space": "␣" ][normalized.key] ?? normalized.key.uppercased())
    }
    func matches(_ other: Self) -> Bool { normalized == other.normalized }
}

struct BrowserShortcutMap: Codable, Equatable, Sendable {
    var bindings: [BrowserAction: BrowserKeyCombo]
    // A missing version identifies the old release. Persisting a version also
    // distinguishes an intentional Cmd-T-only custom map from that old default.
    var schemaVersion: Int? = 1
    static let defaults = Self(bindings: [
        .newTab: .init(key: "t", modifiers: ["command"]),
        .closeTab: .init(key: "w", modifiers: ["command"]),
        .reopenClosedTab: .init(key: "t", modifiers: ["command", "shift"]),
        .back: .init(key: "[", modifiers: ["command"]),
        .forward: .init(key: "]", modifiers: ["command"]),
        .reload: .init(key: "r", modifiers: ["command"]),
        .findInPage: .init(key: "f", modifiers: ["command"]),
        .focusAddressBar: .init(key: "l", modifiers: ["command"]),
        .zoomIn: .init(key: "=", modifiers: ["command"]),
        .zoomOut: .init(key: "-", modifiers: ["command"]),
        .zoomReset: .init(key: "0", modifiers: ["command"]),
        .nextTab: .init(key: "tab", modifiers: ["control"]),
        .previousTab: .init(key: "tab", modifiers: ["control", "shift"]),
        .tabNumber: .init(key: "1", modifiers: ["command"]),
        .printPage: .init(key: "p", modifiers: ["command"]),
        .printPDF: .init(key: "p", modifiers: ["command", "shift"])
    ])
    var upgradedFromLegacy: Self {
        if schemaVersion == nil,
           bindings == [.newTab: BrowserKeyCombo(key: "t", modifiers: ["command"])] { return .defaults }
        var current = self
        current.schemaVersion = 1
        return current
    }
    static let changed = Notification.Name("tatwo.browser.shortcutsChanged")
    static let reserved: [BrowserKeyCombo] = ["q", "h", "m", ",", "n", "s", "z", "x", "c", "v", "a"]
        .map { BrowserKeyCombo(key: $0, modifiers: ["command"]) }
        + [BrowserKeyCombo(key: "a", modifiers: ["command", "shift"]),
           BrowserKeyCombo(key: "z", modifiers: ["command", "shift"]),
           BrowserKeyCombo(key: "h", modifiers: ["command", "option"]),
           BrowserKeyCombo(key: "tab", modifiers: ["command"]),
           BrowserKeyCombo(key: "tab", modifiers: ["command", "shift"]),
           BrowserKeyCombo(key: "space", modifiers: ["command"])]
    static func isReserved(_ combo: BrowserKeyCombo) -> Bool { reserved.contains { $0.matches(combo) } }
    func combos(for action: BrowserAction) -> [BrowserKeyCombo] {
        guard let combo = bindings[action] else { return [] }
        // Both keyboard layouts for Cmd-+ also invoke the conventional Cmd-= binding.
        if action == .zoomIn, combo.matches(.init(key: "=", modifiers: ["command"])) {
            return [combo, .init(key: "=", modifiers: ["command", "shift"]),
                    .init(key: "+", modifiers: ["command", "shift"])]
        }
        return action == .tabNumber ? (1...9).map { BrowserKeyCombo(key: String($0), modifiers: combo.modifiers) } : [combo]
    }
    func invocation(for combo: BrowserKeyCombo) -> BrowserShortcutInvocation? {
        for action in BrowserAction.allCases {
            if let index = combos(for: action).firstIndex(where: { $0.matches(combo) }) {
                return BrowserShortcutInvocation(action: action, number: action == .tabNumber ? index + 1 : 1)
            }
        }
        return nil
    }
    func validationError(for combo: BrowserKeyCombo, action: BrowserAction) -> String? {
        guard !combo.normalized.modifiers.isEmpty else { return "請至少加上一個修飾鍵" }
        if action == .tabNumber && !(1...9).map(String.init).contains(combo.key) {
            return "請使用 1–9 其中一個數字，設定整組分頁快捷鍵"
        }
        var proposed = self
        proposed.bindings[action] = combo.normalized
        for candidate in proposed.combos(for: action) {
            if Self.isReserved(candidate) { return "已被 OS 使用" }
            if let conflict = conflicts(with: candidate, excluding: action).first {
                return "與『\(conflict.title)』相同"
            }
        }
        return nil
    }
    func conflicts(with combo: BrowserKeyCombo, excluding: BrowserAction? = nil) -> [BrowserAction] {
        BrowserAction.allCases.filter { action in
            action != excluding && combos(for: action).contains { $0.matches(combo) }
        }
    }
}

/// Only events claimed synchronously by the native shortcut callback reach this route.
struct BrowserShortcutInvocation: Equatable {
    let action: BrowserAction
    let number: Int
    var message: String { "binding:\(action.rawValue):\(number)" }
    init(action: BrowserAction, number: Int = 1) { self.action = action; self.number = number }
    init?(message: String) {
        let parts = message.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "binding", let action = BrowserAction(rawValue: String(parts[1])),
              let number = Int(parts[2]), (1...9).contains(number), action == .tabNumber || number == 1 else { return nil }
        self.init(action: action, number: number)
    }
}

/// Context-menu actions never depend on a keyboard binding or first-responder change.
enum BrowserNativeMenuAction: String {
    case printPage = "menu:printPage", printPDF = "menu:printPDF", openPDF = "menu:openPDF"
}
