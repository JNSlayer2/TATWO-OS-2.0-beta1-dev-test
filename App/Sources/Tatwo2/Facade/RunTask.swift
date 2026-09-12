import Foundation
import AppKit

/// TATWO2_RUNTASK=<json>：在「看得到的正式 App 視窗」裡，對面板的 sol 下指令。
/// 視窗照常開、討論串照常顯示；任務做完把結果寫到 <json>.result，App 不關，讓使用者看得到整個過程與結果。
/// json：{ "project", "workdir", "thread", "route", "prompt", "timeoutMinutes", "attachments": [] }
enum RunTask {
    private static var attached = false

    @MainActor static func attachIfRequested(_ model: ChatPageModel) {
        guard !attached, model.isLive, let path = ProcessInfo.processInfo.environment["TATWO2_RUNTASK"] else { return }
        attached = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            write(path: path, "RUNTASK 讀不到任務檔"); return
        }
        model.permissionPreset = .approveForMe
        let projectName = spec["project"] as? String ?? "任務"
        let workdir = spec["workdir"] as? String ?? NSHomeDirectory()
        let threadTitle = spec["thread"] as? String ?? projectName
        let routeID = spec["route"] as? String ?? "gpt-5.6-sol"
        let prompt = spec["prompt"] as? String ?? ""
        let timeout = (spec["timeoutMinutes"] as? Double ?? 30) * 60
        Task { @MainActor in
            // 等視窗與資料就緒
            try? await Task.sleep(for: .seconds(2))
            let pid: UUID = model.document.projects.first { $0.name == projectName && $0.workdir == workdir }?.id
                ?? model.acceptanceNewProject(name: projectName, workdir: workdir)!
            let tid: UUID = model.document.projects.first { $0.id == pid }?.threads.first { $0.title == threadTitle }?.id
                ?? model.acceptanceNewThread(in: pid, title: threadTitle)!
            model.selectedThreadID = tid
            if let r = ChatRouteChoice.resolveOrNil(routeID) { model.setSingleModel(r.id) }
            for a in (spec["attachments"] as? [String] ?? []) { model.appendDroppedPath(a) }
            NSApp.activate(ignoringOtherApps: true)
            model.prompt = prompt
            model.send()
            // 視窗開啟時會還原上次選的討論串，送出後再選回本任務的討論串，讓使用者盯著看
            try? await Task.sleep(for: .seconds(3))
            model.selectedThreadID = tid
            let t0 = Date()
            var lastRows = -1
            while model.isRunning && Date().timeIntervalSince(t0) < timeout {
                try? await Task.sleep(for: .seconds(2))
                let rows = model.transcriptMessages.count
                if rows != lastRows { lastRows = rows; print("RUNTASK-PROGRESS secs=\(Int(Date().timeIntervalSince(t0))) rows=\(rows)"); fflush(stdout) }
            }
            let rows = model.transcriptMessages
            let tools = rows.filter { $0.eventKind == .toolUse }
            var out = "RUNTASK project=\(projectName) thread=\(threadTitle) route=\(routeID) running=\(model.isRunning) secs=\(Int(Date().timeIntervalSince(t0))) rows=\(rows.count) tools=\(tools.count)\n"
            for t in tools.suffix(40) { out += "TOOL [\(t.status ?? "")] \(t.text.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))\n" }
            if let last = rows.last(where: { $0.role == .assistant && $0.eventKind == .message }) { out += "REPLY [\(last.status ?? "")]\n" + last.text + "\n" }
            for sys in rows.filter({ $0.role == .system }).suffix(5) { out += "SYSTEM [\(sys.status ?? "")] \(sys.text.prefix(200))\n" }
            out += "END\n"
            print(out); fflush(stdout)
            write(path: path, out)
        }
    }

    private static func write(path: String, _ text: String) {
        try? text.write(toFile: path + ".result", atomically: true, encoding: .utf8)
    }
}
