import Foundation

// Pure data; no PTY, disk writes, network, or LLM calls.
enum CLISessionsFixture {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let records: [CLISessionStore.Record] = (0..<5).map { index in
        CLISessionStore.Record(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 770 + index))!,
            title: ["編譯 Tatwo2", "等候輸入", "測試結束", "上次的工具箱", "文件整理"][index],
            engine: ["codex", "claude", "grok", "generic", "generic"][index],
            cwd: ["/workspace/tatwo2", "/workspace/tools", "/workspace/tests", "/workspace/toolbox", "/workspace/docs"][index],
            createdAt: now.addingTimeInterval(-14_400),
            lastActiveAt: now.addingTimeInterval(index < 3 ? -60 : -10_800),
            status: index == 0 ? .running : (index == 1 ? .waitingInput : .exited),
            exitCode: index == 2 ? 1 : nil, pinned: index == 0, order: index)
    }
    static let output = ["$ swift build --product Tatwo2", "[1/3] Compiling Tatwo2", "Building…"]
}
