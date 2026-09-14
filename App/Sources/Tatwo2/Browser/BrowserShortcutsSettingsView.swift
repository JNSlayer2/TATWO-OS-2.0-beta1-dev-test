import AppKit
import SwiftUI

struct BrowserShortcutsSettingsView: View {
    private let settingsURL: URL
    @State private var map: BrowserShortcutMap
    init(settingsURL: URL = BrowserGeneralSettings.fileURL) {
        self.settingsURL = settingsURL
        _map = State(initialValue: BrowserGeneralSettings.load(from: settingsURL).shortcuts)
    }
    @State private var recording: BrowserAction?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            HStack(alignment: .top) {
                Text("預設只有 ⌘T 新分頁；其餘功能請自行指定").foregroundStyle(.secondary)
                Spacer()
                Button("全部還原預設") { recording = nil; save(.defaults) }
            }
            ForEach(["分頁", "導覽", "檢視", "工具"], id: \.self) { group in
                Text(group).font(.subheadline.bold()).padding(.top, BrowserSettingsMetrics.rowSpacing)
                ForEach(BrowserAction.allCases.filter { $0.group == group }, id: \.self) { action in
                    HStack {
                        Text(action.title)
                        Spacer(minLength: BrowserSettingsMetrics.rowSpacing)
                        Text(display(action)).foregroundStyle(.secondary).monospaced()
                        Button(recording == action ? "取消" : "設定…") {
                            error = nil; recording = recording == action ? nil : action
                        }
                        .accessibilityLabel("\(action.title)\(recording == action ? "取消錄製" : "設定快捷鍵")")
                    }
                    if recording == action {
                        Text(action == .tabNumber ? "按下修飾鍵＋1–9（整組）；Esc 取消，Delete 清除" : "按下組合鍵；Esc 取消，Delete 清除")
                            .font(.caption).foregroundStyle(.secondary)
                        BrowserShortcutRecorder { combo in accept(combo, for: action) } cancel: { recording = nil; error = nil }
                            .frame(height: 1)
                        if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    }
                }
            }
            if recording == nil, let error { Text(error).foregroundStyle(.red) }
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserShortcutMap.changed)) { _ in
            map = BrowserGeneralSettings.load(from: settingsURL).shortcuts
        }
    }
    private func display(_ action: BrowserAction) -> String {
        guard let combo = map.bindings[action] else { return "未設定" }
        return action == .tabNumber ? BrowserKeyCombo(key: "1–9", modifiers: combo.modifiers).display : combo.display
    }
    private func accept(_ combo: BrowserKeyCombo?, for action: BrowserAction) {
        guard let combo else {
            var next = map; next.bindings[action] = nil
            if save(next) { recording = nil }; return
        }
        if let message = map.validationError(for: combo, action: action) { error = message; return }
        var next = map; next.bindings[action] = combo.normalized
        if save(next) { recording = nil }
    }
    @discardableResult private func save(_ next: BrowserShortcutMap) -> Bool {
        do { try BrowserGeneralSettings.saveShortcuts(next, to: settingsURL); map = next; error = nil; return true }
        catch { self.error = "快捷鍵儲存失敗：\(error.localizedDescription)"; return false }
    }
}

/// A first-responder recorder, never a global monitor; leaving the row tears it down.
private struct BrowserShortcutRecorder: NSViewRepresentable {
    var record: (BrowserKeyCombo?) -> Void
    var cancel: () -> Void
    final class Capture: NSView {
        var record: ((BrowserKeyCombo?) -> Void)?
        var cancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancel?(); return }
            if event.keyCode == 51 || event.keyCode == 117 { record?(nil); return }
            guard let combo = BrowserKeyCombo(event: event) else { return }
            record?(combo)
        }
    }
    func makeNSView(context: Context) -> Capture {
        let view = Capture(); view.record = record; view.cancel = cancel; return view
    }
    func updateNSView(_ view: Capture, context: Context) { view.record = record; view.cancel = cancel }
}
