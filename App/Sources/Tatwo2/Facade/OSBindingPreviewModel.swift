import AppKit
import Combine

@MainActor final class OSBindingPreviewModel: ObservableObject {
    @Published var preview: OSBindingPreview?
    @Published var busy = false
    @Published var report = ""

    func load(environment: [String: String]) {
        guard !busy else { return }
        busy = true
        preview = nil
        report = ""
        Task {
            let result = await Task.detached { OSUpstreamBinding.preview(environment: environment) }.value
            preview = result
            busy = false
        }
    }

    func confirm(environment: [String: String], completed: @escaping () -> Void) {
        guard !busy, let plan = preview, plan.error == nil, !plan.paths.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "確認寫入修復？"
        alert.informativeText = "只更新 V2 綁定區塊。既有檔先備份；任一檔失敗即停止，已寫入的保留，不回復其他人的內容。\n" +
            (plan.seed ? "入口缺少上游檔：先種入內建 os-upstream.md 與 os.md v3；原 os.md 保留為 os.1.0.md。\n" : "") +
            "下方列出所有修改路徑及備份位置（可捲動）。"
        let paths = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        paths.isEditable = false
        paths.isSelectable = true
        paths.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        paths.string = "將修改的路徑：\n" + plan.paths.joined(separator: "\n") + "\n備份位置：\n" + plan.root + "/backups/bindings/<日期>/<序號>/<原檔名>"
        paths.isVerticallyResizable = true
        paths.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
        scroll.hasVerticalScroller = true
        scroll.documentView = paths
        alert.accessoryView = scroll
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "寫入修復")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            let result = await Task.detached { OSUpstreamBinding.apply(plan, environment: environment) }.value
            report = result.text
            preview = nil
            busy = false
            completed()
        }
    }
}
