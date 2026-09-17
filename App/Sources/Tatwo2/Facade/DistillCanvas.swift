import Foundation
import SwiftUI
import Darwin

enum DistillCanvas {
    static let headings = ["這段做了什麼", "架構現況", "決策與理由", "教訓", "下一步"]
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func byteEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func argument(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(whereSeparator: \.isWhitespace).first == "/蒸餾" else { return nil }
        return String(text.dropFirst("/蒸餾".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func newPlan(threadID: UUID, argument: String) -> TatwoPlanArtifactV1 {
        TatwoPlanArtifactV1(threadID: threadID, objective: argument.isEmpty ? "這段工作蒸餾" : argument,
                            sections: headings.map { .init(title: $0, body: "") }, kind: "distill")
    }

    /// Strip only the Markdown fence delimiter, not the draft's whitespace.
    static func draft(from reply: String) -> String? {
        var body: [String]?
        var nested: String?
        var outside: String?
        var result: String?
        for line in reply.components(separatedBy: "\n") {
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if body == nil {
                if let fence = outside {
                    if token == fence { outside = nil }
                } else if token == "```tatwo-plan" {
                    body = []
                } else if token.hasPrefix("```") || token.hasPrefix("~~~") {
                    outside = String(token.prefix { $0 == "`" || $0 == "~" })
                }
            } else if let fence = nested {
                body?.append(line)
                if token == fence { nested = nil }
            } else if token == "```" {
                let text = body!.joined(separator: "\n")
                if complete(text) { result = text }
                body = nil
            } else {
                body?.append(line)
                if token.hasPrefix("```") || token.hasPrefix("~~~") {
                    nested = String(token.prefix { $0 == "`" || $0 == "~" })
                }
            }
        }
        return result
    }

    static func complete(_ text: String) -> Bool {
        // Validation may inspect a trimmed copy; storage and delivery use `text`.
        let inspected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\0"), text.utf8.count <= 1024 * 1024,
              let sections = TatwoPlanArtifactV1.parseSections(fromReply: "```tatwo-plan\n\(inspected)\n```") else { return false }
        return headings.allSatisfy { title in
            let matches = sections.filter { $0.title == title }
            return matches.count == 1 && !matches[0].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func title(for text: String) -> String {
        String((text.components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
        } ?? "工作蒸餾").prefix(80))
    }

    static func slug(for title: String, id: UUID) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        let words = latin.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        let stem = String(words.joined(separator: "-").prefix(64))
        return "distill/\(stem.isEmpty ? "work" : stem)-\(id.uuidString.lowercased().prefix(8))"
    }

    /// Pinned W80b's parser trims boundary whitespace and extracts timeline
    /// markers. Reject unrepresentable bodies BEFORE writing; never silently edit.
    static func gbrainBodyProblem(_ text: String) -> String? {
        if text != text.trimmingCharacters(in: .whitespacesAndNewlines) || text.contains("\r") {
            return "GBrain 會正規化首尾空白或 CR 換行；請手動改成無首尾空白的 LF 正文，才可逐字寫入。"
        }
        if text.range(of: #"(?im)^\s*(?:<!--\s*timeline\s*-->|##\s+(?:timeline|history)\b|---\s*$)"#,
                      options: .regularExpression) != nil {
            return "GBrain 會解析 Timeline／History／分隔線；請先移除這些特殊標記，或只選 skillet。"
        }
        return nil
    }

    static func validate(_ submission: DistillSubmission, available: Bool) throws {
        guard submission.gbrain || submission.skillet else { throw Failure(reason: "請先選擇去處。") }
        guard complete(submission.content) else { throw Failure(reason: "請填好五個固定段落。") }
        if submission.gbrain {
            guard available else { throw Failure(reason: "GBrain 不可用；未寫入。") }
            guard submission.slug.range(of: #"^[a-z0-9][a-z0-9/_-]{0,159}$"#, options: .regularExpression) != nil,
                  !submission.slug.contains("//"),
                  !submission.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !submission.title.contains("\n"), !submission.title.contains("\r") else {
                throw Failure(reason: "請填標題及有效 slug（小寫英數、/、-、_）。")
            }
            if let reason = gbrainBodyProblem(submission.content) { throw Failure(reason: reason) }
        }
    }

    /// Keep the exact preview baseline; W78 compares again under its write lock.
    static func writeSkillet(_ content: String, base: String, dispatch: DeviceDispatch = .shared) throws -> String {
        let identity = try dispatch.identity()
        if identity.role == .secondary {
            return try proposeSkillet(content, base: base, dispatch: dispatch)
        }
        let outcome = try OSDocuments.writeFromDevice(id: "skillet", text: content, base: base,
                                                     source: identity.name)
        guard try byteEqual(OSDocuments.read(id: "skillet"), content) else {
            throw Failure(reason: "skillet 已嘗試寫入，但讀回不一致；請檢查，勿直接重送。")
        }
        return "skillet：\(outcome.message)"
    }

    /// W78 document_propose eagerly applies and mirrors its ACK locally. Rule
    /// distillation instead uses W78's review-only branch inbox, with an isolated
    /// two-commit proposal. Neither entrance nor user's source worktree is edited.
    static func proposeSkillet(_ content: String, base: String, dispatch: DeviceDispatch) throws -> String {
        let identity = try dispatch.identity()
        guard identity.role == .secondary else { throw Failure(reason: "只有副設備送提案。") }
        let id = UUID().uuidString.lowercased()
        let directory = dispatch.root.appendingPathComponent("distill-proposals").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        func git(_ arguments: [String]) throws -> String {
            let (code, data) = try DeviceDispatch.run("/usr/bin/git",
                ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                 "-c", "core.attributesFile=/dev/null", "-c", "core.autocrlf=false",
                 "-c", "user.name=TATWO distill", "-c", "user.email=distill@localhost"] + arguments,
                directory: directory)
            guard code == 0 else { throw Failure(reason: "無法建立 skillet 提案；原稿保留在 \(directory.path)") }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "--quiet", "--template="])
        let file = directory.appendingPathComponent("skillet.md")
        try Data(base.utf8).write(to: file, options: .atomic)
        _ = try git(["add", "--", "skillet.md"])
        _ = try git(["commit", "--quiet", "-m", "skillet preview base"])
        try Data(content.utf8).write(to: file, options: .atomic)
        _ = try git(["add", "--", "skillet.md"])
        _ = try git(["commit", "--quiet", "--allow-empty", "-m", "Propose entrance skillet distillation"])
        let commit = try git(["rev-parse", "HEAD"])
        let (readCode, readBytes) = try DeviceDispatch.run("/usr/bin/git", ["show", "\(commit):skillet.md"], directory: directory)
        guard readCode == 0, readBytes == Data(content.utf8) else {
            throw Failure(reason: "提案原文讀回不一致；未傳送，請檢查 \(directory.path)")
        }
        let ref = "refs/heads/inbox/\(identity.deviceID)/distill/\(id)/\(commit)"
        do {
            try dispatch.pushSubmission(repository: directory, commit: commit, ref: ref)
            let reply = try dispatch.callPrimary(method: "inbox_receive", payload: [
                "branch": ref, "commit": commit,
                "message": "skillet 蒸餾提案；請審閱此分支 skillet.md 的差異，再整合到主設備入口。本機副本未改。"])
            guard reply["received"] as? Bool == true else { throw Failure(reason: "收件未確認") }
        } catch {
            throw Failure(reason: "主設備收件未確認；提案保留於 \(directory.path)，不會自動重送。本機 skillet.md 未改。")
        }
        return "skillet 提案已進主設備 W78 收件箱：\(ref)\n本機 skillet.md 未改。"
    }
}

/// Extension lives with the canvas: no alternate DB/credential/SSH implementation.
/// W80's managed adapter connects to the existing GBrainService and stamps device.
extension GBrainService {
    func putDistillation(_ submission: DistillSubmission) async throws -> String {
        guard healthy, let definition = Self.definition(environment: ProcessInfo.processInfo.environment) else {
            throw DistillCanvas.Failure(reason: "GBrain 不可用：\(status)")
        }
        return try await Task.detached(priority: .userInitiated) {
            try DistillGBrainClient.write(submission, definition: definition)
        }.value
    }
}

/// A bounded, short-lived stdio client for the existing OS-owned MCP adapter.
enum DistillGBrainClient {
    static func write(_ submission: DistillSubmission, definition: [String: Any]) throws -> String {
        try DistillCanvas.validate(submission, available: true)
        guard let command = definition["command"] as? String, let args = definition["args"] as? [String] else {
            throw DistillCanvas.Failure(reason: "缺少 GBrain adapter。")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command); process.arguments = args
        process.standardInput = input; process.standardOutput = output
        // Do not collect potentially sensitive diagnostics in application logs.
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        var buffer = Data()
        func send(_ object: [String: Any]) throws {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
        }
        func response(_ id: Int) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    guard object["error"] == nil, let result = object["result"] as? [String: Any],
                          result["isError"] as? Bool != true else {
                        throw DistillCanvas.Failure(reason: "GBrain 拒絕請求；若已送出寫入，請先查頁面，勿直接重送。")
                    }
                    return result
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                if ready > 0 {
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    guard count > 0 else { throw DistillCanvas.Failure(reason: "GBrain 連線中斷；請先查頁面，勿直接重送。") }
                    buffer.append(contentsOf: bytes.prefix(count))
                    guard buffer.count <= 4 * 1024 * 1024 else {
                        throw DistillCanvas.Failure(reason: "GBrain 回覆過大。")
                    }
                }
            }
            throw DistillCanvas.Failure(reason: "GBrain 逾時；結果未確認，請先查頁面，勿直接重送。")
        }
        func call(_ id: Int, _ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                      "params": ["name": name, "arguments": arguments]])
            return try response(id)
        }
        func pageObject(_ result: [String: Any]) -> [String: Any]? {
            if let structured = result["structuredContent"] as? [String: Any] { return structured }
            for item in result["content"] as? [[String: Any]] ?? [] {
                if let text = item["text"] as? String, let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
            }
            return nil
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2024-11-05", "capabilities": [:],
            "clientInfo": ["name": "tatwo-distill", "version": "1"]]])
        _ = try response(1)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        // Metadata is a separate envelope; the body is never re-rendered or trimmed.
        let quotedTitle = String(decoding: try JSONEncoder().encode(submission.title), as: UTF8.self)
        let content = "---\ntitle: \(quotedTitle)\ntype: note\n---\n" + submission.content
        _ = try call(2, "put_page", ["slug": submission.slug, "content": content])
        let readback = try call(3, "get_page", ["slug": submission.slug])
        guard let page = pageObject(readback), let body = page["compiled_truth"] as? String,
              DistillCanvas.byteEqual(body, submission.content) else {
            throw DistillCanvas.Failure(reason: "GBrain 已寫入 \(submission.slug)，但正文讀回不一致；請檢查，勿直接重送。")
        }
        return submission.slug
    }
}

struct DistillPlanActions: View {
    let artifact: TatwoPlanArtifactV1
    let isDisabled: Bool
    let onSubmission: (UUID, DistillSubmission) -> Bool
    @ObservedObject private var service = GBrainService.shared
    @State private var gbrain = false
    @State private var skillet = false
    @State private var title = ""
    @State private var slug = ""
    @State private var metadataEdited = false
    @State private var previewBase: String?
    @State private var previewContent: String?
    @State private var busy = false
    @State private var message = ""

    private var locked: Bool { busy || artifact.distillSubmission != nil }
    private var content: String { artifact.editableText() }
    private var previewCurrent: Bool {
        previewContent.map { DistillCanvas.byteEqual($0, content) } == true && previewBase != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先編輯畫布；要 AI 再改寫，請在對話輸入修改要求。未按送出不寫入任何目的地。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("GBrain", isOn: $gbrain).disabled(!service.healthy)
                Toggle("skillet", isOn: $skillet)
                Button("兩者") { gbrain = service.healthy; skillet = true }.disabled(!service.healthy)
            }
            .disabled(locked || isDisabled)
            if !service.healthy { Text("GBrain 不可用：\(service.status)。仍可選 skillet。").foregroundStyle(.secondary) }
            if gbrain {
                TextField("標題", text: Binding(get: { title }, set: { title = $0; metadataEdited = true }))
                TextField("slug", text: Binding(get: { slug }, set: { slug = $0; metadataEdited = true }))
                if let reason = DistillCanvas.gbrainBodyProblem(content) { Text(reason).foregroundStyle(.orange) }
            }
            if skillet && !locked {
                Text(service.isPrimary ? "送出將替換入口 skillet.md 全文；請先查看差異。" :
                        "副設備只送 skillet 提案到主設備，本機 skillet.md 不變。")
                Button("預覽 skillet 差異") {
                    do {
                        previewBase = try OSDocuments.read(id: "skillet")
                        previewContent = content
                    } catch { message = error.localizedDescription }
                }.disabled(isDisabled)
                if previewCurrent, let base = previewBase {
                    DisclosureGroup("差異預覽：以下舊全文將替換成畫布全文", isExpanded: .constant(true)) {
                        Text("− 舊全文\n" + base).foregroundStyle(.red).textSelection(.enabled)
                        Text("+ 新全文\n" + content).foregroundStyle(.green).textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            if let submission = artifact.distillSubmission {
                Text("GBrain slug：\(submission.gbrain ? submission.slug : "未選")\n\(submission.message)").textSelection(.enabled)
            }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
            HStack {
                Button("取消選擇") {
                    gbrain = false; skillet = false; previewBase = nil; previewContent = nil; message = ""
                }.disabled(locked)
                Button(busy ? "送出中…" : "送出") { submit() }
                    .disabled(locked || isDisabled || (!gbrain && !skillet) || (gbrain && !service.healthy)
                              || !DistillCanvas.complete(content) || (skillet && !previewCurrent))
                    .accessibilityIdentifier("distill-submit")
            }
        }
        .disabled(locked)
        .onAppear { deriveMetadata(); service.refresh() }
        .onChange(of: content) { _, _ in
            previewBase = nil; previewContent = nil
            if !metadataEdited { deriveMetadata() }
        }
        .onChange(of: service.healthy) { _, healthy in if !healthy { gbrain = false } }
    }

    private func deriveMetadata() {
        title = DistillCanvas.title(for: content)
        slug = DistillCanvas.slug(for: title, id: artifact.planID)
    }

    private func submit() {
        guard !locked, !isDisabled, !skillet || previewCurrent else { return }
        var snapshot = DistillSubmission(threadID: artifact.threadID, content: content, title: title,
                                        slug: slug, gbrain: gbrain, skillet: skillet)
        do { try DistillCanvas.validate(snapshot, available: service.healthy) }
        catch { message = error.localizedDescription; return }
        // No destination is touched until this human action and durable boundary.
        guard onSubmission(artifact.planID, snapshot) else { message = "畫布已改變或無法保存；未送出。"; return }
        let base = previewBase
        busy = true
        Task { @MainActor in
            var results: [String] = []
            if snapshot.gbrain {
                do { results.append("GBrain 已寫入並逐字讀回：\(try await service.putDistillation(snapshot))") }
                catch { results.append("GBrain：\(error.localizedDescription)") }
            }
            if snapshot.skillet, let base {
                do {
                    let text = snapshot.content
                    results.append(try await Task.detached {
                        try DistillCanvas.writeSkillet(text, base: base)
                    }.value)
                }
                catch { results.append("skillet：\(error.localizedDescription)") }
            }
            snapshot.message = results.joined(separator: "\n")
            if !onSubmission(artifact.planID, snapshot) {
                message = snapshot.message + "\n結果無法存回畫布；請先查目的地，勿直接重送。"
            }
            busy = false
        }
    }
}
