import CryptoKit
import Darwin
import Foundation

/// W78 uses the existing SSH/RPC channel only. A bundle is accepted only as a
/// response fetched from the host key pinned to device.json's current primary.
/// There deliberately is no RPC that accepts an arbitrary inbound bundle.
final class DeviceDispatch: @unchecked Sendable {
    static let shared = DeviceDispatch()
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    struct Bundle: Codable {
        var sender: String
        var recipient: String
        var epoch: Int
        var seq: UInt64
        var files: [String: Data]
        var hashes: [String: String]
        var transfer: PrimaryTransfer.Record? = nil
    }
    struct Receipt: Codable {
        var seq: UInt64
        var phase: String
        var hashes: [String: String]
        var updated: Date
        var detail: String?
        var attemptAt: Date?
        var transfer: PrimaryTransfer.ACK? = nil
    }
    struct State: Codable {
        var next: UInt64 = 0
        var received: [String: UInt64] = [:]
        var epoch: Int = 0
        var receipts: [String: Receipt] = [:]
        /// Handoff metadata and ordinary document pulls can run in opposite
        /// directions after the source switch; never overwrite an outstanding ACK.
        var transferOffers: [String: Receipt]? = nil
    }
    let entry: TatwoEntry
    let registry: DeviceRegistry
    let root: URL
    let environment: [String: String]
    let retireBackup: ((URL) -> Void)?
    /// In-process test transport only; no environment or RPC can enable it.
    private let rpc: ((DeviceRecord, String, [String: Any]) throws -> [String: Any])?
    private let push: ((URL, String, String, String) throws -> Void)?
    private let evidence: (() -> PrimaryTransfer.Evidence)?
    lazy var inbox = DeviceInbox(dispatch: self)
    private let lock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "ai.tatwo.tatwo2.dispatch")
    private var timer: DispatchSourceTimer?

    init(entry: TatwoEntry = TatwoEntry(), registry: DeviceRegistry = DeviceRegistry(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         retireBackup: ((URL) -> Void)? = nil,
         rpc: ((DeviceRecord, String, [String: Any]) throws -> [String: Any])? = nil,
         push: ((URL, String, String, String) throws -> Void)? = nil,
         evidence: (() -> PrimaryTransfer.Evidence)? = nil) {
        self.entry = entry; self.registry = registry; self.environment = environment
        self.retireBackup = retireBackup
        self.rpc = rpc
        self.push = push
        self.evidence = evidence
        root = registry.root.appendingPathComponent("dispatch", isDirectory: true)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Descriptor-relative, no-follow read. Never traverse a note/ symlink.
    static func readFile(_ path: String, root: URL, readOnly: Bool = false) throws -> Data? {
        let parts = try RemoteThreadTransfer.validatedRelativePath(path).split(separator: "/").map(String.init)
        var fd = Darwin.open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(reason: "entry_unreadable") }
        defer { Darwin.close(fd) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return nil }
                throw Failure(reason: "unsafe_file_parent")
            }
            Darwin.close(fd); fd = next
        }
        let file = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure(reason: "unsafe_file")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 4 * 1024 * 1024 else { throw Failure(reason: "not_a_bounded_regular_file") }
        let data = try handle.readToEnd() ?? Data()
        if readOnly, fchmod(file, 0o444) != 0 { throw Failure(reason: "readonly_mode_failed") }
        return data
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    func identity() throws -> DeviceIdentity {
        guard let local = try DeviceIdentityStore.readLocal(entry: entry),
              local.epoch != nil, local.primaryDeviceID != nil else { throw Failure(reason: "authority_unknown") }
        return local
    }
    func primary() throws -> DeviceRecord {
        let local = try identity()
        guard local.role == .secondary,
              let peer = registry.list().first(where: { $0.id.lowercased() == local.primaryDeviceID?.lowercased() })
        else { throw Failure(reason: "primary_not_paired") }
        return peer
    }
    private func state() throws -> State {
        let file = root.appendingPathComponent("state.json")
        if !FileManager.default.fileExists(atPath: file.path) { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
    }
    private func save(_ value: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    func receipts(now: Date = Date()) -> [String: Receipt] {
        lock.lock(); defer { lock.unlock() }
        guard let state = try? state() else { return [:] }
        return state.receipts.mapValues { receipt in
            var row = receipt
            if row.phase != "converged", now.timeIntervalSince(row.updated) > 60 {
                row.phase = "timeout"
            }
            return row
        }
    }
    private func notePaths() throws -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.noteDir.path) {
            guard (try? fm.destinationOfSymbolicLink(atPath: entry.noteDir.path)) == nil else {
                throw Failure(reason: "note_symlink")
            }
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: entry.noteDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw Failure(reason: "notes_unreadable")
            }
            // The enumerator yields resolved paths; the entrance may be reached through
            // a symlink (mini: ~/AI/TATWO OS → /Volumes/…), so strip the resolved prefix.
            let notePrefix = entry.noteDir.resolvingSymlinksInPath().path
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= 2048 else { throw Failure(reason: "dispatch_too_many_paths") }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                    throw Failure(reason: "note_symlink_or_special_file")
                }
                if values.isRegularFile == true {
                    let resolved = url.resolvingSymlinksInPath().path
                    guard resolved.hasPrefix(notePrefix + "/") else { throw Failure(reason: "note_outside_entry") }
                    paths.append("note/" + String(resolved.dropFirst(notePrefix.count + 1)))
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return paths
    }
    func snapshot() throws -> [String: Data] {
        let paths = try ["os.md", "skillet.md"] + notePaths()
        guard paths.count <= 512 else { throw Failure(reason: "dispatch_too_many_files") }
        var result: [String: Data] = [:], bytes = 0
        for path in paths {
            guard let data = try Self.readFile(path, root: entry.root) else {
                throw Failure(reason: "dispatch_missing_file")
            }
            bytes += data.count
            guard bytes <= 4 * 1024 * 1024 else { throw Failure(reason: "dispatch_too_large") }
            result[path] = data
        }
        return result
    }
    /// Removed replica notes are archived, never deleted. Descriptor-relative
    /// renames cannot follow a replaced note parent or an archive symlink.
    /// If interrupted, the receipt stays applied; a fresh sequence finishes the
    /// remaining moves and must read back the entire manifest before converging.
    private func archiveRemovedNotes(_ paths: [String], seq: UInt64) throws {
        guard !paths.isEmpty else { return }
        let rootFD = Darwin.open(entry.root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure(reason: "entry_unreadable") }
        defer { Darwin.close(rootFD) }
        guard mkdirat(rootFD, "archive", 0o700) == 0 || errno == EEXIST else {
            throw Failure(reason: "archive_unavailable")
        }
        let archiveFD = openat(rootFD, "archive", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard archiveFD >= 0 else { throw Failure(reason: "unsafe_archive") }
        defer { Darwin.close(archiveFD) }
        let name = "w78-notes-\(seq)-" + UUID().uuidString
        guard mkdirat(archiveFD, name, 0o700) == 0 else { throw Failure(reason: "archive_unavailable") }
        let destination = openat(archiveFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw Failure(reason: "archive_unavailable") }
        defer { Darwin.close(destination) }
        let manifest = "# Archived replica notes\nRestore each numbered file to its relative path under the entrance.\n"
            + paths.enumerated().map { "\($0.offset).note → \($0.element)" }.joined(separator: "\n") + "\n"
        let manifestFD = openat(destination, "MANIFEST.md", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard manifestFD >= 0 else { throw Failure(reason: "archive_manifest_unavailable") }
        let handle = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: true)
        try handle.write(contentsOf: Data(manifest.utf8)); try handle.close()
        for (index, path) in paths.enumerated() {
            let parts = try RemoteThreadTransfer.validatedRelativePath(path).split(separator: "/").map(String.init)
            guard parts.first == "note", let leaf = parts.last,
                  try Self.readFile(path, root: entry.root) != nil else { throw Failure(reason: "unsafe_removed_note") }
            var parent = dup(rootFD)
            guard parent >= 0 else { throw Failure(reason: "archive_unavailable") }
            defer { Darwin.close(parent) }
            for part in parts.dropLast() {
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure(reason: "unsafe_removed_note") }
                Darwin.close(parent); parent = next
            }
            guard renameat(parent, leaf, destination, "\(index).note") == 0 else {
                throw Failure(reason: "note_archive_interrupted")
            }
        }
    }
    /// Read-only payload creation except for the durable sequence / receipt ledger.
    func offer(to recipient: String) throws -> Bundle {
        lock.lock(); defer { lock.unlock() }
        let local = try identity()
        let handoff = local.transfer.flatMap { $0.from == local.deviceID ? $0 : nil }
        guard (local.role == .primary || handoff?.participants.contains(recipient) == true),
              registry.list().contains(where: { $0.id == recipient }) else {
            throw Failure(reason: "not_primary_or_unknown_recipient")
        }
        if let transfer = local.transfer, transfer.to == local.deviceID, !transfer.constitution {
            throw Failure(reason: "constitution_source_not_transferred")
        }
        let files: [String: Data] = handoff?.constitution == true ? [:] : try snapshot()
        let hashes = files.mapValues(Self.hash)
        var state = try state()
        guard local.epoch! >= state.epoch else { throw Failure(reason: "stale_local_authority") }
        guard state.next < UInt64.max else { throw Failure(reason: "sequence_exhausted") }
        state.epoch = local.epoch!
        state.next += 1
        let previous = state.receipts[recipient]
        let started = previous?.phase != "converged" && previous?.hashes == hashes ? previous!.updated : Date()
        state.receipts[recipient] = Receipt(seq: state.next, phase: "delivered", hashes: hashes,
                                          updated: started, attemptAt: Date())
        if handoff != nil {
            var offers = state.transferOffers ?? [:]
            offers[recipient] = state.receipts[recipient]
            state.transferOffers = offers
        }
        try save(state)
        return Bundle(sender: local.deviceID, recipient: recipient, epoch: local.epoch!,
                      seq: state.next, files: files, hashes: hashes, transfer: handoff)
    }
    /// Internal transport-bound entry, never exposed through OSAgentBridge.perform.
    func apply(_ bundle: Bundle, authenticatedPrimary: DeviceRecord) throws -> Receipt {
        lock.lock(); defer { lock.unlock() }
        let local = try identity()
        if let transfer = bundle.transfer {
            var state = try state()
            guard bundle.epoch >= max(local.epoch!, state.epoch),
                  bundle.seq > (state.received[bundle.sender] ?? 0),
                  bundle.files.mapValues(Self.hash) == bundle.hashes else {
                throw Failure(reason: "stale_epoch_or_replayed_transfer")
            }
            let receipt = try PrimaryTransfer.accept(transfer, bundle: bundle,
                                                     peer: authenticatedPrimary, dispatch: self)
            state.epoch = bundle.epoch
            state.received[bundle.sender] = bundle.seq
            state.receipts[bundle.sender] = receipt
            try save(state)
            return receipt
        }
        guard local.role == .secondary,
              authenticatedPrimary.id.lowercased() == local.primaryDeviceID?.lowercased(),
              registry.list().contains(where: { $0.id == authenticatedPrimary.id
                  && $0.publicKeyFingerprint == authenticatedPrimary.publicKeyFingerprint }),
              bundle.sender.lowercased() == authenticatedPrimary.id.lowercased(),
              bundle.recipient.lowercased() == local.deviceID.lowercased()
        else { throw Failure(reason: "not_current_primary") }
        var state = try state()
        guard bundle.epoch >= max(local.epoch!, state.epoch) else { throw Failure(reason: "stale_epoch") }
        guard bundle.seq > (state.received[bundle.sender] ?? 0) else { throw Failure(reason: "replayed_sequence") }
        guard bundle.files.count <= 512, bundle.files["os.md"] != nil, bundle.files["skillet.md"] != nil,
              bundle.files.values.reduce(0, { $0 + $1.count }) <= 4 * 1024 * 1024,
              bundle.files.mapValues(Self.hash) == bundle.hashes else { throw Failure(reason: "content_hash_mismatch") }
        for path in bundle.files.keys {
            _ = try RemoteThreadTransfer.validatedRelativePath(path)
            guard path == "os.md" || path == "skillet.md" || path.hasPrefix("note/") else {
                throw Failure(reason: "dispatch_path_outside_allowlist")
            }
        }
        // Consume before writing. A crash/retry must obtain a fresh sequence, never
        // reuse a cached converged ACK. File transaction recovery is W72's writer.
        state.epoch = bundle.epoch
        state.received[bundle.sender] = bundle.seq
        state.receipts[bundle.sender] = Receipt(seq: bundle.seq, phase: "delivered", hashes: [:], updated: Date())
        try save(state)
        let removed = Set(try notePaths()).subtracting(bundle.files.keys).sorted()
        let baselines = try RemoteThreadTransfer.baselines(paths: Array(bundle.files.keys), in: entry.root.path)
        let files = bundle.files.filter { baselines[$0.key] != bundle.hashes[$0.key] }.map { RemoteThreadTransferFile(relativePath: $0.key,
            base64: $0.value.base64EncodedString(), baseSHA256: baselines[$0.key]) }
        try RemoteThreadTransfer.write(files, to: entry.root.path, retire: retireBackup)
        var receipt = Receipt(seq: bundle.seq, phase: "applied", hashes: [:], updated: Date())
        state.receipts[bundle.sender] = receipt; try save(state)
        try archiveRemovedNotes(removed, seq: bundle.seq)
        for path in bundle.files.keys {
            guard let readback = try Self.readFile(path, root: entry.root, readOnly: true) else {
                throw Failure(reason: "readback_missing")
            }
            receipt.hashes[path] = Self.hash(readback)
        }
        guard receipt.hashes == bundle.hashes,
              try snapshot().mapValues(Self.hash) == bundle.hashes else { throw Failure(reason: "readback_mismatch") }
        receipt.phase = "converged"; receipt.updated = Date()
        state.receipts[bundle.sender] = receipt; try save(state)
        if let transfer = local.transfer, !transfer.committed, transfer.from == bundle.sender,
           local.epoch == transfer.oldEpoch {
            // The still-current primary cancelled before committing the epoch.
            // An ordinary pinned bundle restores W78 alignment, not a takeover.
            var restored = local; restored.transfer = nil; restored.updatedAt = Date()
            try DeviceIdentityStore.forLocalDevice(entry: entry, pairedDeviceID: local.deviceID).write(restored)
        }
        return receipt
    }
    func recordACK(_ receipt: Receipt, sender: String) throws {
        lock.lock(); defer { lock.unlock() }
        var state = try state()
        let offered = receipt.transfer == nil ? state.receipts[sender] : state.transferOffers?[sender]
        guard let sent = offered, sent.seq == receipt.seq,
              receipt.phase == "converged", sent.hashes == receipt.hashes,
              Date().timeIntervalSince(sent.attemptAt ?? sent.updated) <= 60 else { throw Failure(reason: "invalid_or_late_ack") }
        if let transfer = receipt.transfer {
            try PrimaryTransfer.acknowledge(transfer, sender: sender, dispatch: self)
        }
        state.receipts[sender] = Receipt(seq: sent.seq, phase: "converged", hashes: receipt.hashes, updated: Date())
        try save(state)
    }
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: 10)
        timer.setEventHandler { [weak self] in self?.synchronize() }
        self.timer = timer; timer.resume()
    }
    func align(targetDeviceID: String? = nil, regenerateRules: Bool = false) {
        // Injected test transports are driven synchronously; never race test roots.
        guard rpc == nil else { return }
        worker.async {
            if (try? self.identity().role) == .primary {
                for peer in self.registry.list() where targetDeviceID == nil || peer.id == targetDeviceID {
                    try? RemoteHostLink(environment: self.environment).notifyDispatch(device: peer)
                }
            } else {
                self.synchronize()
                if regenerateRules, let primary = try? self.primary(),
                   self.receipts()[primary.id]?.phase == "converged" {
                    // W68 ownership checks preserve customized output. Translating
                    // constitution+identity into new rule content remains W79.
                    _ = OSUpstreamRefresh.applyOnLaunch()
                }
            }
        }
    }
    func synchronize() {
        do {
            let local = try identity()
            // The destination continues pulling the former primary's checkpoint
            // after promotion. The authority exception is scoped to this handoff.
            if let transfer = local.transfer, transfer.to == local.deviceID, !transfer.complete,
               let former = registry.list().first(where: { $0.id == transfer.from }) {
                try pullTransfer(from: former)
                return
            }
            if local.role == .primary {
                lock.lock(); defer { lock.unlock() }
                let hashes = try snapshot().mapValues(Self.hash)
                var state = try state()
                for peer in registry.list() where state.receipts[peer.id]?.hashes != hashes {
                    state.receipts[peer.id] = Receipt(seq: 0, phase: "pending", hashes: hashes, updated: Date())
                }
                try save(state)
                return
            }
            let peer = try primary()
            inbox.flush()
            let response = try send(peer, method: "dispatch_fetch", params: signed(method: "dispatch_fetch", payload: [:]))
            let bundle = try Self.decode(Bundle.self, response)
            guard !inbox.proposals().contains(where: {
                ($0.document == "os" || $0.document == "skillet") && $0.status != "sent"
            }) else { throw Failure(reason: "pending_document_keeps_local_original") }
            let receipt = try apply(bundle, authenticatedPrimary: peer)
            // apply may promote this device; ACK must still go to the pinned sender.
            _ = try send(peer, method: "dispatch_ack",
                         params: signed(method: "dispatch_ack", payload: Self.object(receipt), recipient: peer.id))
        } catch {
            lock.lock(); defer { lock.unlock() }
            if var state = try? state(), let local = try? identity(), let id = local.primaryDeviceID {
                var row = state.receipts[id] ?? Receipt(seq: 0, phase: "delivered", hashes: [:], updated: Date())
                // Preserve first failure time, so repeated outages cannot postpone timeout.
                if row.phase == "converged" { row.phase = "delivered"; row.updated = Date() }
                row.detail = error.localizedDescription
                state.receipts[id] = row
                try? save(state)
            }
        }
    }

    // Client proof uses the SAME paired SSH key. Never read/export private key bytes.
    // Forwarded UNIX sockets do not carry SSH client identity; self-reported UUIDs
    // are not authentication. Keychain / the legacy Ed25519 signer are not used.
    func callPrimary(method: String, payload: [String: Any]) throws -> [String: Any] {
        let peer = try primary()
        let proof = try signed(method: method, payload: payload)
        return try send(peer, method: method, params: proof)
    }
    private func send(_ peer: DeviceRecord, method: String, params: [String: Any]) throws -> [String: Any] {
        if let rpc { return try rpc(peer, method, params) }
        return try RemoteHostLink(environment: environment).callPinned(device: peer, method: method, params: params)
    }
    func pushSubmission(repository: URL, commit: String, ref: String) throws {
        let peer = try primary()
        let link = RemoteHostLink(environment: environment)
        let params = try signed(method: "inbox_target", payload: [:])
        let target = try rpc?(peer, "inbox_target", params)
            ?? link.callPinned(device: peer, method: "inbox_target", params: params)
        guard let path = target["repository"] as? String, path.hasPrefix("/"), !path.contains("\n") else {
            throw Failure(reason: "invalid_primary_repository")
        }
        if rpc != nil {
            guard let push else { throw Failure(reason: "test_push_not_injected") }
            try push(repository, path, commit, ref)
        } else {
            try link.pushPinned(device: peer, repository: path, localRepository: repository, commit: commit, ref: ref)
        }
    }
    func signed(method: String, payload: [String: Any], recipient: String? = nil) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let local = try identity()
        var state = try state()
        guard state.next < UInt64.max else { throw Failure(reason: "sequence_exhausted") }
        state.next += 1; try save(state)
        let body: [String: Any] = ["method": method, "sender": local.deviceID,
            "recipient": recipient ?? local.primaryDeviceID!, "epoch": local.epoch!, "seq": state.next, "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let key = environment["TATWO2_SSH_KEY_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        let publicKey = try String(contentsOfFile: key + ".pub", encoding: .utf8)
        // Prefer the already-unlocked SSH agent using only the public-key path.
        // A noninteractive file-key fallback still uses the same paired key;
        // encrypted/unavailable keys fail closed, never trigger Keychain prompts.
        var result: (Int32, Data) = (1, Data())
        if environment["SSH_AUTH_SOCK"]?.isEmpty == false {
            result = try Self.run("/usr/bin/ssh-keygen",
                ["-Y", "sign", "-f", key + ".pub", "-n", "tatwo2-rpc"], input: data)
        }
        if result.0 != 0 {
            result = try Self.run("/usr/bin/ssh-keygen",
                ["-Y", "sign", "-f", key, "-P", "", "-n", "tatwo2-rpc"], input: data)
        }
        guard result.0 == 0 else { throw Failure(reason: "paired_ssh_signing_unavailable") }
        return ["body": data.base64EncodedString(), "signature": result.1.base64EncodedString(), "publicKey": publicKey]
    }
    func authenticate(method: String, proof: [String: Any]) throws -> (String, [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let local = try identity()
        let handoff = local.transfer.flatMap { $0.from == local.deviceID ? $0 : nil }
        let handoffMethod = method == "dispatch_fetch" || method == "dispatch_ack"
        guard (local.role == .primary || (handoff != nil && handoffMethod)),
              let raw = proof["body"] as? String, let data = Data(base64Encoded: raw), data.count <= 5 * 1024 * 1024,
              let sig = proof["signature"] as? String, let signature = Data(base64Encoded: sig), signature.count < 8192,
              let publicKey = proof["publicKey"] as? String,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["method"] as? String == method, body["recipient"] as? String == local.deviceID,
              let sender = body["sender"] as? String,
              let peer = registry.list().first(where: { $0.id == sender }),
              try DeviceRegistry.fingerprint(publicKey: publicKey) == peer.publicKeyFingerprint,
              let epoch = body["epoch"] as? Int, let seq = body["seq"] as? UInt64,
              let payload = body["payload"] as? [String: Any]
        else { throw Failure(reason: "untrusted_rpc_sender") }
        let authorized = try String(contentsOf: registry.authorizedKeysURL, encoding: .utf8)
        let components = publicKey.split(whereSeparator: \.isWhitespace)
        guard components.count >= 2, !publicKey.contains("\r"),
              authorized.split(separator: "\n").contains(where: { line in
                  let fields = line.split(whereSeparator: \.isWhitespace)
                  return fields.count >= 2 && fields[0] == components[0] && fields[1] == components[1]
              }) else { throw Failure(reason: "revoked_rpc_key") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("w78-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let allowed = scratch.appendingPathComponent("allowed"), signatureFile = scratch.appendingPathComponent("signature")
        try Data("paired \(components[0]) \(components[1])\n".utf8).write(to: allowed)
        try signature.write(to: signatureFile)
        let result = try Self.run("/usr/bin/ssh-keygen", ["-Y", "verify", "-f", allowed.path,
            "-I", "paired", "-n", "tatwo2-rpc", "-s", signatureFile.path], input: data)
        guard result.0 == 0 else { throw Failure(reason: "invalid_ssh_proof") }
        var state = try state()
        let pendingHandoff = handoffMethod && handoff?.participants.contains(sender) == true
            && epoch == handoff?.oldEpoch && handoff?.epochACKs.contains(sender) == false
        guard ((epoch == local.epoch! && epoch >= state.epoch) || pendingHandoff),
              seq > (state.received[sender] ?? 0) else {
            throw Failure(reason: "stale_epoch_or_replayed_sequence")
        }
        state.epoch = max(state.epoch, local.epoch!); state.received[sender] = seq; try save(state)
        return (sender, payload)
    }
    func transferEvidence() -> PrimaryTransfer.Evidence {
        evidence?() ?? PrimaryTransfer.evidence(entry: entry)
    }
    func transferIdentity(_ peer: DeviceRecord) throws -> DeviceIdentity {
        let snapshot = try DeviceStatusSnapshot.decode(send(peer, method: "device_status", params: [:]))
        guard let identity = snapshot.identity.value,
              DeviceStatusPolicy.fresh(snapshot.identity.acquiredAt, now: Date()) else {
            throw Failure(reason: "現任主設備須在線才能移交")
        }
        return identity
    }
    func beginTransfer(to target: String, signingName: String) throws {
        lock.lock(); defer { lock.unlock() }
        try PrimaryTransfer.begin(self, to: target, signingName: signingName)
    }
    func updateTransfer(constitution: Bool = false, brain: PrimaryTransfer.Brain? = nil,
                        release: Bool = false, signingName: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try PrimaryTransfer.update(self, constitution: constitution, brain: brain, release: release, signingName: signingName)
    }
    func cancelPreparedTransfer() throws {
        lock.lock(); defer { lock.unlock() }
        try PrimaryTransfer.cancelPrepared(self)
    }
    func pullTransfer(from peer: DeviceRecord) throws {
        let response = try send(peer, method: "dispatch_fetch",
                                params: signed(method: "dispatch_fetch", payload: [:], recipient: peer.id))
        let receipt = try apply(Self.decode(Bundle.self, response), authenticatedPrimary: peer)
        _ = try send(peer, method: "dispatch_ack",
                     params: signed(method: "dispatch_ack", payload: Self.object(receipt), recipient: peer.id))
    }
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    directory: URL? = nil) throws -> (Int32, Data) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.environment?["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment?["SSH_ASKPASS"] = "/usr/bin/false"
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        var temporary: URL?, handle: FileHandle?
        if let input {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("w78-input-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            temporary = folder
            let url = folder.appendingPathComponent("input")
            try input.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            handle = try FileHandle(forReadingFrom: url); process.standardInput = handle
        } else { process.standardInput = FileHandle.nullDevice }
        defer { try? handle?.close(); if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + 10)
        deadline.setEventHandler { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        deadline.resume()
        defer { deadline.cancel() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
