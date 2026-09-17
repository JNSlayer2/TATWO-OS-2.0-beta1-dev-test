import Foundation

/// Durable proposals and branch receipts live with the existing local device state.
/// No staging, checkout, stash, reset, or commit is run on a submitting secondary.
final class DeviceInbox: @unchecked Sendable {
    static var shared: DeviceInbox { DeviceDispatch.shared.inbox }
    struct Proposal: Codable, Identifiable {
        var id: String
        var document: String
        var base: String
        var text: String
        var primaryText: String?
        var status: String
        var commit: String?
        var localBase: String?
        var localText: String?
        var updated: Date?
        var error: String?
    }
    struct Branch: Codable, Identifiable {
        var id: String
        var sender: String
        var branch: String
        var commit: String
        var message: String
        var received: Date
    }
    private let dispatch: DeviceDispatch
    private let lock = NSRecursiveLock()
    init(dispatch: DeviceDispatch) { self.dispatch = dispatch }
    private var pendingURL: URL { dispatch.root.appendingPathComponent("outbox.json") }
    private var inboxURL: URL { dispatch.root.appendingPathComponent("inbox.json") }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: dispatch.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    func proposals() -> [Proposal] {
        lock.lock(); defer { lock.unlock() }
        return (try? read([Proposal].self, from: pendingURL)) ?? []
    }
    func branches() -> [Branch] {
        lock.lock(); defer { lock.unlock() }
        return (try? read([Branch].self, from: inboxURL)) ?? []
    }
    func enqueue(id: String, text: String, base: String) throws -> OSDocuments.WriteOutcome {
        lock.lock(); defer { lock.unlock() }
        guard ["os", "skillet", "todo", "issue"].contains(id), text.utf8.count <= 1024 * 1024,
              try dispatch.identity().role == .secondary else {
            throw DeviceDispatch.Failure(reason: "invalid_secondary_document")
        }
        var rows = try read([Proposal].self, from: pendingURL) ?? []
        if let index = rows.firstIndex(where: { $0.document == id && $0.status != "sent" }) {
            guard rows[index].status != "conflict" else { throw DeviceDispatch.Failure(reason: "請先選擇三方差異") }
            // A previous payload may already be in flight. A new draft is a new
            // proposal, never a different body under an idempotency key in use.
            if rows[index].text != text { rows[index].id = UUID().uuidString }
            rows[index].text = text
            rows[index].error = nil
        } else {
            rows.append(Proposal(id: UUID().uuidString, document: id, base: base, text: text,
                                 status: "pending", localBase: base, updated: Date()))
        }
        try save(rows, to: pendingURL)
        // Do not block the UI on SSH. The 10-second coordinator handles online and
        // offline saves identically and resumes from this durable queue after restart.
        dispatch.align()
        return .secondary
    }
    func flush() {
        // Never hold the outbox lock across SSH. Offline saves and UI reads must
        // remain usable while a previous network request is timing out.
        let pending: [Proposal]
        lock.lock()
        do { pending = try read([Proposal].self, from: pendingURL) ?? [] }
        catch { lock.unlock(); return }
        lock.unlock()
        for proposal in pending where proposal.status == "pending" {
            do {
                let path = try relativePath(proposal.document)
                let before = try DeviceDispatch.readFile(path, root: dispatch.entry.root)
                let original = Data((proposal.localBase ?? proposal.base).utf8)
                let desired = Data(proposal.text.utf8)
                if before != original && before != desired {
                    let response = try dispatch.callPrimary(method: "document_inspect", payload: ["id": proposal.document])
                    guard let primary = response["text"] as? String else {
                        throw DeviceDispatch.Failure(reason: "invalid_document_response")
                    }
                    lock.lock(); defer { lock.unlock() }
                    var rows = try read([Proposal].self, from: pendingURL) ?? []
                    guard let index = rows.firstIndex(where: { $0.id == proposal.id && $0.status == "pending" }) else { continue }
                    rows[index].localText = before.map { String(decoding: $0, as: UTF8.self) }
                    rows[index].primaryText = primary; rows[index].status = "conflict"
                    try save(rows, to: pendingURL)
                    continue
                }
                let response = try dispatch.callPrimary(method: "document_propose",
                    payload: DeviceDispatch.object(proposal))
                guard let status = response["status"] as? String else {
                    throw DeviceDispatch.Failure(reason: "invalid_document_response")
                }
                lock.lock(); defer { lock.unlock() }
                var rows = try read([Proposal].self, from: pendingURL) ?? []
                guard let index = rows.firstIndex(where: { $0.id == proposal.id && $0.status == "pending" }) else { continue }
                rows[index].error = nil
                if status == "conflict" {
                    guard let text = response["primaryText"] as? String else {
                        throw DeviceDispatch.Failure(reason: "missing_conflict_text")
                    }
                    rows[index].primaryText = text; rows[index].status = "conflict"
                } else if status == "sent" {
                    // A changed local original is also a conflict, never silently
                    // overwritten because the primary successfully committed.
                    let path = try relativePath(rows[index].document)
                    let current = try DeviceDispatch.readFile(path, root: dispatch.entry.root)
                    let base = Data((rows[index].localBase ?? rows[index].base).utf8), desired = Data(rows[index].text.utf8)
                    guard current == base || current == desired else {
                        rows[index].localText = current.map { String(decoding: $0, as: UTF8.self) }
                        rows[index].primaryText = rows[index].text
                        rows[index].status = "conflict"
                        try save(rows, to: pendingURL)
                        continue
                    }
                    if current != desired {
                        try RemoteThreadTransfer.write([RemoteThreadTransferFile(relativePath: path,
                            base64: desired.base64EncodedString(),
                            baseSHA256: current.map(DeviceDispatch.hash) ?? RemoteThreadTransfer.missing)],
                            to: dispatch.entry.root.path, retire: dispatch.retireBackup)
                    }
                    rows[index].status = "sent"; rows[index].commit = response["commit"] as? String
                    rows[index].updated = Date()
                } else { throw DeviceDispatch.Failure(reason: response["message"] as? String ?? status) }
                try save(rows, to: pendingURL)
            } catch {
                lock.lock(); defer { lock.unlock() }
                if var rows = try? read([Proposal].self, from: pendingURL),
                   let index = rows.firstIndex(where: { $0.id == proposal.id && $0.status == "pending" }) {
                    rows[index].error = error.localizedDescription
                    try? save(rows, to: pendingURL)
                }
                // Keep the preimage and retry with a fresh authenticated sequence.
            }
        }
    }
    func resolve(id: String, useProposal: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var rows = try read([Proposal].self, from: pendingURL) ?? []
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].status == "conflict",
              let primary = rows[i].primaryText else { throw DeviceDispatch.Failure(reason: "no_conflict") }
        // Only the user's choice changes the proposal. Neither original is changed
        // here. The next CAS still protects against a further primary edit.
        rows[i].base = primary
        if !useProposal { rows[i].text = primary }
        if let current = try DeviceDispatch.readFile(try relativePath(rows[i].document), root: dispatch.entry.root) {
            rows[i].localBase = String(decoding: current, as: UTF8.self)
        }
        rows[i].localText = nil
        rows[i].primaryText = nil; rows[i].status = "pending"; rows[i].id = UUID().uuidString
        try save(rows, to: pendingURL); dispatch.align()
    }
    private func relativePath(_ id: String) throws -> String {
        switch id {
        case "os": return "os.md"
        case "skillet": return "skillet.md"
        case "todo": return "tatwo2/docs/todo.md"
        case "issue": return "tatwo2/docs/issue.md"
        default: throw DeviceDispatch.Failure(reason: "document_not_allowed")
        }
    }
    func inspectDocument(_ id: String) throws -> String {
        guard try dispatch.identity().role == .primary,
              let data = try DeviceDispatch.readFile(try relativePath(id), root: dispatch.entry.root),
              let text = String(data: data, encoding: .utf8) else {
            throw DeviceDispatch.Failure(reason: "document_unavailable")
        }
        return text
    }
    func receiveDocument(_ payload: [String: Any], sender: String) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let proposal = try DeviceDispatch.decode(Proposal.self, payload)
        guard UUID(uuidString: proposal.id) != nil, proposal.text.utf8.count <= 1024 * 1024 else {
            throw DeviceDispatch.Failure(reason: "invalid_proposal")
        }
        _ = try relativePath(proposal.document)
        let expected = dispatch.entry.root.appendingPathComponent(try relativePath(proposal.document))
        guard let document = OSDocuments.list().first(where: { $0.id == proposal.document }),
              URL(fileURLWithPath: document.path).resolvingSymlinksInPath() == expected.resolvingSymlinksInPath(),
              try DeviceDispatch.readFile(try relativePath(proposal.document), root: dispatch.entry.root) != nil else {
            throw DeviceDispatch.Failure(reason: "document_adapter_outside_primary_entry")
        }
        if proposal.document == "todo" || proposal.document == "issue" {
            let (status, data) = try DeviceDispatch.run("/usr/bin/git",
                ["symbolic-ref", "--quiet", "--short", "HEAD"], directory: dispatch.entry.repoRoot)
            guard status == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "beta1/integration" else {
                throw DeviceDispatch.Failure(reason: "primary_not_on_integration")
            }
        }
        let receiptURL = dispatch.root.appendingPathComponent("document-\(sender)-\(proposal.id).json")
        if let cached = try read(Proposal.self, from: receiptURL) {
            guard cached.document == proposal.document, cached.text == proposal.text, cached.base == proposal.base else {
                throw DeviceDispatch.Failure(reason: "proposal_id_reused")
            }
            return ["status": "sent", "commit": cached.commit ?? ""]
        }
        let current = try OSDocuments.read(id: proposal.document)
        guard current == proposal.base else { return ["status": "conflict", "primaryText": current] }
        guard let peer = dispatch.registry.list().first(where: { $0.id == sender }) else {
            throw DeviceDispatch.Failure(reason: "sender_no_longer_paired")
        }
        let source = String(peer.name.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ") + " / " + sender
        let outcome = try OSDocuments.writeFromDevice(id: proposal.document, text: proposal.text,
            base: proposal.base, source: source)
        if case .commitFailed(let reason) = outcome { return ["status": "commit_failed", "message": reason] }
        guard try OSDocuments.read(id: proposal.document) == proposal.text else {
            throw DeviceDispatch.Failure(reason: "document_readback_mismatch")
        }
        var receipt = proposal; receipt.status = "sent"
        if proposal.document == "todo" || proposal.document == "issue" {
            let path = "docs/\(proposal.document).md"
            let (status, data) = try DeviceDispatch.run("/usr/bin/git",
                ["log", "-1", "--format=%H", "--", path], directory: dispatch.entry.repoRoot)
            let commit = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0, DeviceStatusReader.validCommit(commit) else {
                throw DeviceDispatch.Failure(reason: "document_commit_unavailable")
            }
            let (found, content) = try DeviceDispatch.run("/usr/bin/git",
                ["show", "\(commit):\(path)"], directory: dispatch.entry.repoRoot)
            guard found == 0, content == Data(proposal.text.utf8) else {
                throw DeviceDispatch.Failure(reason: "document_commit_readback_mismatch")
            }
            receipt.commit = commit
        }
        try save(receipt, to: receiptURL)
        return ["status": "sent", "commit": receipt.commit ?? ""]
    }
    func receiveBranch(_ payload: [String: Any], sender: String) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let ref = payload["branch"] as? String, let commit = payload["commit"] as? String,
              let message = payload["message"] as? String, !message.isEmpty, message.utf8.count <= 8192,
              ref.hasPrefix("refs/heads/inbox/\(sender)/"), DeviceStatusReader.validCommit(commit) else {
            throw DeviceDispatch.Failure(reason: "invalid_branch_receipt")
        }
        let (status, data) = try DeviceDispatch.run("/usr/bin/git", ["rev-parse", "--verify", ref + "^{commit}"],
                                                   directory: dispatch.entry.repoRoot)
        guard status == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == commit else {
            throw DeviceDispatch.Failure(reason: "branch_not_received")
        }
        var rows = try read([Branch].self, from: inboxURL) ?? []
        let id = sender + ":" + ref + ":" + commit
        if !rows.contains(where: { $0.id == id }) {
            rows.append(Branch(id: id, sender: sender, branch: ref, commit: commit, message: message, received: Date()))
            try save(rows, to: inboxURL)
        }
        return ["received": true]
    }
    func submit(message: String) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceDispatch.Failure(reason: "請填提交說明")
        }
        let local = try dispatch.identity()
        let repo = dispatch.entry.repoRoot
        func git(_ args: [String]) throws -> String {
            let (status, data) = try DeviceDispatch.run("/usr/bin/git", args, directory: repo)
            guard status == 0 else { throw DeviceDispatch.Failure(reason: "git_submission_failed") }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let branch = try git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let commit = try git(["rev-parse", "--verify", "HEAD^{commit}"])
        let ref = "refs/heads/inbox/\(local.deviceID)/\(branch)/\(commit)"
        try dispatch.pushSubmission(repository: repo, commit: commit, ref: ref)
        _ = try dispatch.callPrimary(method: "inbox_receive",
            payload: ["branch": ref, "commit": commit, "message": message])
        return "已提交 \(branch)；副設備 HEAD、index、工作樹未變"
    }
}
