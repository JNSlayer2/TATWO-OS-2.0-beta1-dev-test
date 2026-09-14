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
    static let defaults = Self(bindings: [.newTab: BrowserKeyCombo(key: "t", modifiers: ["command"])])
    static let changed = Notification.Name("tatwo.browser.shortcutsChanged")
    static let reserved: [BrowserKeyCombo] = ["q", "w", "h", "m", ",", "n", "s", "l", "z", "x", "c", "v", "a"]
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
        return action == .tabNumber ? (1...9).map { BrowserKeyCombo(key: String($0), modifiers: combo.modifiers) } : [combo]
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

// W57a callback keys. No default action is inferred from these names.
extension BrowserShortcutMap {
    static func legacyCombo(_ kind: String) -> BrowserKeyCombo? {
        let key: String
        switch kind {
        case "reopen": return BrowserKeyCombo(key: "t", modifiers: ["command", "shift"])
        case "back": key = "["
        case "forward": key = "]"
        case "find": key = "f"
        case "print": key = "p"
        case "focusAddress": key = "l"
        case "newTab": key = "t"
        case "closeTab": key = "w"
        case "reload": key = "r"
        case "printPDF": return BrowserKeyCombo(key: "p", modifiers: ["command", "shift"])
        // The bridge collapses Cmd-= and Cmd-Shift-=; never execute the wrong binding.
        case "zoomIn": return nil
        case "zoomOut": key = "-"
        case "zoomReset": key = "0"
        default:
            guard kind.hasPrefix("tab"), let n = Int(kind.dropFirst(3)), (1...9).contains(n) else { return nil }
            key = String(n)
        }
        return BrowserKeyCombo(key: key, modifiers: ["command"])
    }
}
