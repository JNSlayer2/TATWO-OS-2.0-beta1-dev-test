import Foundation

/// B3 派工卡的資料合約（ultrawork 2.0）：主討論串底下的子討論串＝房間。
/// 第 2 步做派工引擎時，動作接真的；現在是最小實作（停＝中斷該串、看＝切過去、合併＝把報告收成一則貼回主串）。
struct DispatchRoom: Identifiable, Equatable {
    let id: UUID
    let title: String
    let engineLabel: String
    let liveness: ThreadLiveness
    let lastOutputAt: Date?
    let reportAvailable: Bool
    let deviceLabel: String?
    let isRunning: Bool
    var needsAttention: Bool { liveness == .failed || liveness == .stalled || (!isRunning && liveness != .done) }
    var statusLabel: String {
        if isRunning { return liveness == .idle ? "工作中 · 暫無輸出" : "工作中" }
        return liveness == .done ? "已完成" : liveness == .failed ? "已失敗" : "狀態待確認"
    }

    init(id: UUID, title: String, engineLabel: String, liveness: ThreadLiveness, lastOutputAt: Date?, reportAvailable: Bool, deviceLabel: String? = nil, isRunning: Bool? = nil) {
        self.id = id
        self.title = title
        self.engineLabel = engineLabel
        self.liveness = liveness
        self.lastOutputAt = lastOutputAt
        self.reportAvailable = reportAvailable
        self.deviceLabel = deviceLabel
        self.isRunning = isRunning ?? (liveness == .active || liveness == .idle)
    }
}

extension ChatPageModel {
    static var exportChatScene: String? { ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] }
    /// `dispatch`＝既有金樣；`dispatch-failed`＝同佈局、房間 B 改「已失敗」的 fixture 預覽（2026-09-06 liveness failed 呈現）。
    static var isDispatchExportScene: Bool { exportChatScene == "dispatch" || exportChatScene == "dispatch-failed" }

    var dispatchRooms: [DispatchRoom] { dispatchRooms(parent: selectedThreadID) }

    func dispatchRooms(parent: UUID?) -> [DispatchRoom] {
        if !isLive {
            guard Self.isDispatchExportScene else { return [] }
            let roomBLiveness: ThreadLiveness = Self.exportChatScene == "dispatch-failed" ? .failed : .idle
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            return [
                DispatchRoom(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B301")!, title: "房間A 升版與遷移", engineLabel: "sol", liveness: .active, lastOutputAt: now.addingTimeInterval(-180), reportAvailable: false),
                DispatchRoom(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B302")!, title: "房間B Discord 外掛", engineLabel: "sol", liveness: roomBLiveness, lastOutputAt: now.addingTimeInterval(-6 * 60), reportAvailable: false),
                DispatchRoom(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B303")!, title: "副審", engineLabel: "opus", liveness: .done, lastOutputAt: now.addingTimeInterval(-20 * 60), reportAvailable: true),
            ]
        }
        guard let selected = parent else { return [] }
        return document.projects.flatMap(\.threads)
            .filter { $0.parentThreadID == selected && $0.liveness != nil }
            .map { t in
                let record = live?.threadRecord(t.id)
                let label = record?.deviceID.flatMap { id in
                    try? RemoteDeviceLookup(root: live?.store.url.deletingLastPathComponent()).device(id: id).name
                }
                return DispatchRoom(id: t.id, title: t.title, engineLabel: t.engineLabel ?? "", liveness: t.liveness ?? .idle, lastOutputAt: t.lastOutputAt, reportAvailable: t.liveness == .done, deviceLabel: label, isRunning: live?.isRunning(t.id) ?? false)
            }
    }

    var machinePressureSummary: String {
        if !isLive { return "記憶體 51%・負載 4.3" }
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } } == KERN_SUCCESS
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let free = ok ? Double(stats.free_count + stats.inactive_count) * Double(vm_kernel_page_size) : 0
        let used = total > 0 ? Int((1 - free / total) * 100) : 0
        var load = [Double](repeating: 0, count: 3); getloadavg(&load, 3)
        return "記憶體 \(used)%・負載 \(String(format: "%.1f", load[0]))"
    }

    func openDispatchRoom(_ id: UUID) { selectedThreadID = id }

    func toggleDispatchReport(_ id: UUID) {
        if expandedDispatchReports.contains(id) { expandedDispatchReports.remove(id) } else { expandedDispatchReports.insert(id) }
    }

    /// 房間報告摘錄：該房最後一則助理回覆的前 14 行；沒有就說沒有。
    func dispatchReportExcerpt(_ id: UUID) -> String {
        if !isLive {
            return "副審結論：兩房 diff 皆可合併。\n- 房間A：遷移腳本有 rollback，測試 12/12 綠。\n- 房間B：外掛註冊改用 manifest，缺 e2e（已標未跑）。\n建議：先合 A，B 補 e2e 後再合。"
        }
        guard let live else { return "（尚無報告）" }
        let rows = live.transcript(for: id)
        guard let reply = rows.last(where: { $0.role == .assistant && $0.eventKind == .message }) else { return "（尚無報告）" }
        let lines = reply.text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(14).joined(separator: "\n")
        return lines.count > 14 ? head + "\n…（其餘在討論串）" : head
    }

    func stopDispatchRoom(_ id: UUID) { live?.stop(threadID: id) }

    func stopAllDispatchRooms(parent: UUID? = nil) { for room in dispatchRooms(parent: parent ?? selectedThreadID) where room.isRunning { stopDispatchRoom(room.id) } }

    /// 把每個房間的最終回覆收成一段文字，直接以 system 訊息貼回主討論串，並回傳合併文字。
    @discardableResult
    func mergeDispatchReports(parent: UUID? = nil) -> String {
        guard let live, let parent = parent ?? selectedThreadID else { return "" }
        var parts: [String] = []
        for room in dispatchRooms(parent: parent) {
            let rows = live.transcript(for: room.id)
            let reply: ChatMessage? = rows.last(where: { $0.role == .assistant && $0.eventKind == .message })
            let text: String = reply?.text ?? "（尚無報告）"
            let header: String = "## " + room.title + "（" + room.engineLabel + "）"
            parts.append(header + "\n" + text)
        }
        let joined: String = parts.joined(separator: "\n\n")
        guard !joined.isEmpty else { return "" }
        live.appendSystemMessage(threadID: parent, text: "合併報告：\n\n" + joined)
        return joined
    }
}
