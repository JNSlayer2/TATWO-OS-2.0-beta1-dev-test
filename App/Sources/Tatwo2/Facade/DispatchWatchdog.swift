// 房間 E2：監工哨兵。規格＝docs/os.md §2「監工」與 §5。
// ChatLiveEngine 啟動時掛上；每 60 秒（測試可用 TATWO2_WATCHDOG_INTERVAL_SEC 覆寫）巡檢：
// 1) 子討論串活性（5 分鐘無輸出＝idle 提醒、15 分鐘零輸出＝stalled 自動停止）
// 2) 機器壓力（記憶體/負載過高時暫停新派工，降回來時恢復）
// 警報一律貼回子討論串所屬的主討論串，同一件事只貼一次直到狀態改變。
import Foundation

@MainActor
final class DispatchWatchdog {
    private weak var engine: ChatLiveEngine?
    private var timer: Timer?
    private var idleWarned: Set<UUID> = []
    private var pressurePaused = false
    private var pressureNotified: Set<UUID> = []

    private init(engine: ChatLiveEngine) { self.engine = engine }

    @discardableResult
    static func attach(to engine: ChatLiveEngine, environment: [String: String] = ProcessInfo.processInfo.environment) -> DispatchWatchdog {
        let watchdog = DispatchWatchdog(engine: engine)
        let interval = environment["TATWO2_WATCHDOG_INTERVAL_SEC"].flatMap(Double.init) ?? 60
        watchdog.start(interval: interval)
        return watchdog
    }

    private func start(interval: TimeInterval) {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        guard let engine else { return }
        checkLiveness(engine)
        checkPressure(engine)
        engine.onChange?()
    }

    // MARK: - 活性

    private func checkLiveness(_ engine: ChatLiveEngine) {
        for t in engine.doc.threads where t.subStatus == "running" {
            guard let parentID = t.parentThreadID else { continue }
            let liveness = ThreadLiveness.from(status: t.subStatus, lastOutputAt: t.lastOutputAt) ?? .active
            switch liveness {
            case .stalled:
                engine.stop(threadID: t.id)
                engine.markSubStatus(t.id, "stalled")
                engine.appendSystemMessage(threadID: parentID, text: "房間 \(t.title) 15 分鐘零輸出，已自動停止")
                idleWarned.remove(t.id)
            case .idle:
                if !idleWarned.contains(t.id) {
                    engine.appendSystemMessage(threadID: parentID, text: "房間 \(t.title) 5 分鐘沒有輸出")
                    idleWarned.insert(t.id)
                }
            case .active, .done, .failed:   // failed 由引擎事件標記，巡檢不再處置
                idleWarned.remove(t.id)
            }
        }
    }

    // MARK: - 機器壓力

    private func checkPressure(_ engine: ChatLiveEngine) {
        let stats = DispatchWatchdog.machineStats()
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        let highPressure = stats.usedMemoryPercent > 85 || stats.load1 > cores * 1.5
        let recovered = stats.usedMemoryPercent < 80 && stats.load1 < cores * 1.2
        let summary = "記憶體 \(stats.usedMemoryPercent)%・負載 \(String(format: "%.1f", stats.load1))"
        let targets = pressureTargets(engine)
        pressureNotified.formIntersection(targets)
        if highPressure {
            pressurePaused = true
            engine.dispatchPaused = true
        } else if pressurePaused && recovered {
            pressurePaused = false
            engine.dispatchPaused = false
            for id in pressureNotified { engine.appendSystemMessage(threadID: id, text: "壓力恢復，可派工") }
            pressureNotified.removeAll()
        }
        if pressurePaused {
            for id in targets.subtracting(pressureNotified) {
                engine.appendSystemMessage(threadID: id, text: "機器壓力高（\(summary)），暫停新派工")
            }
            pressureNotified.formUnion(targets)
        }
    }

    /// 只通知仍有工作中的子串且尚存在的主串，不污染歷史或目前選取的無關聊天。
    private func pressureTargets(_ engine: ChatLiveEngine) -> Set<UUID> {
        let existing = Set(engine.doc.threads.map(\.id))
        return Set(engine.doc.threads
            .filter { $0.subStatus == "running" }
            .compactMap(\.parentThreadID)).intersection(existing)
    }

    struct MachineStats { var usedMemoryPercent: Int; var load1: Double }

    /// 算法照 ChatPageModel.machinePressureSummary（DispatchRooms.swift）；這層不依賴 ChatPageModel，故重算一次。
    static func machineStats() -> MachineStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        } == KERN_SUCCESS
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let free = ok ? Double(stats.free_count + stats.inactive_count) * Double(vm_kernel_page_size) : 0
        let used = total > 0 ? Int((1 - free / total) * 100) : 0
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return MachineStats(usedMemoryPercent: used, load1: load[0])
    }
}
