import Foundation

/// A resumable handoff over W78's pinned pull + signed ACK channel.
/// Each endpoint writes only its own identity. No database or private key is moved.
enum PrimaryTransfer {
    typealias Brain = PrimaryTransferState.Brain
    typealias Release = PrimaryTransferState.Release
    typealias Evidence = PrimaryTransferState.Evidence
    typealias Record = PrimaryTransferState.Record
    typealias ACK = PrimaryTransferState.ACK

    static let migrationSteps = [
        "1. 在舊主設備停止資料寫入，依目前資料庫後端匯出並保留備份；不要將含密碼連線字串放進移交記錄。",
        "2. 在新主設備依同一後端的匯入流程操作；本精靈不執行匯出、匯入或搬動正式資料。",
        "3. 啟動新服務，檢查健康與兩端頁數一致，再選「已遷移」並驗證；頁數一致不等同逐頁內容驗證。",
        "保留舊服務時，須先手動確認新主設備仍能連到舊服務；不會自動建立第二個資料庫。"
    ]

    static func fail(_ reason: String) -> DeviceDispatch.Failure { .init(reason: reason) }

    static func save(_ record: Record, dispatch: DeviceDispatch, commit: Bool = false) throws {
        var local = try dispatch.identity()
        if commit {
            guard local.epoch == record.oldEpoch || local.epoch == record.epoch else {
                throw fail("transfer_stale_epoch")
            }
            local.epoch = record.epoch
            local.primaryDeviceID = record.to
            local.role = local.deviceID == record.to ? .primary : .secondary
        }
        local.transfer = record; local.updatedAt = Date()
        let store = try DeviceIdentityStore.forLocalDevice(entry: dispatch.entry,
                                                          pairedDeviceID: local.deviceID)
        try store.write(local)
        if commit {
            // Keep the existing registry's role projection in sync; never replace
            // keys, endpoints, local resources, or pairing identities.
            for var peer in dispatch.registry.list() {
                peer.role = peer.id == record.to ? .primary : .secondary
                peer.epoch = record.epoch
                _ = try dispatch.registry.add(peer)
            }
        }
    }

    /// Must run on the current primary. An offline peer cannot manufacture a handoff.
    static func begin(_ dispatch: DeviceDispatch, to target: String, signingName: String) throws {
        let local = try dispatch.identity()
        guard local.role == .primary, local.primaryDeviceID == local.deviceID else {
            throw fail("現任主設備須在線才能移交")
        }
        guard local.transfer == nil || local.transfer!.complete || local.transfer!.from != local.deviceID else {
            throw fail("transfer_in_progress_retry_existing")
        }
        if let previous = local.transfer, previous.to == local.deviceID, !previous.epochComplete {
            // Do not strand an offline observer behind two authority changes.
            throw fail("先完成所有設備的 epoch 讀回，再移交回原主設備")
        }
        guard let peer = dispatch.registry.list().first(where: { $0.id == target }), target != local.deviceID,
              let epoch = local.epoch, epoch < Int.max else { throw fail("invalid_transfer_target") }
        let remote = try dispatch.transferIdentity(peer)
        guard remote.deviceID == target, remote.role == .secondary,
              remote.epoch == epoch, remote.primaryDeviceID == local.deviceID else {
            throw fail("target_authority_mismatch")
        }
        let source = dispatch.transferEvidence()
        let record = Record(from: local.deviceID, to: target, oldEpoch: epoch, epoch: epoch + 1,
                            participants: dispatch.registry.list().map(\.id).sorted(),
                            previousTransferID: local.transfer?.id,
                            sourceDeviceID: local.deviceID, sourceRoot: dispatch.entry.root.path,
                            hashes: try dispatch.snapshot().mapValues(DeviceDispatch.hash),
                            sourcePages: source.brainHealthy ? source.pages : nil,
                            signingName: signingName)
        try save(record, dispatch: dispatch)
        dispatch.align()
    }

    /// The former primary only retains authority to finish this exact recorded
    /// handoff. It cannot issue another epoch, alter the destination, or take over.
    static func update(_ dispatch: DeviceDispatch, constitution: Bool = false,
                       brain: Brain? = nil, release: Bool = false, signingName: String? = nil) throws {
        let local = try dispatch.identity()
        guard var record = local.transfer, record.from == local.deviceID, record.epochComplete,
              let peer = dispatch.registry.list().first(where: { $0.id == record.to }) else {
            throw fail("transfer_epoch_pending")
        }
        let remote = try dispatch.transferIdentity(peer)
        guard remote.role == .primary, remote.epoch == record.epoch,
              remote.transfer?.id == record.id else { throw fail("現任主設備須在線才能移交") }
        guard let evidence = record.targetEvidence, Date().timeIntervalSince(evidence.acquiredAt) <= 60,
              Date().timeIntervalSince(evidence.acquiredAt) >= -5 else { throw fail("target_evidence_stale_retry") }
        if constitution {
            guard try dispatch.snapshot().mapValues(DeviceDispatch.hash) == record.hashes,
                  let root = record.targetRoot else { throw fail("constitution_hash_changed_retry") }
            record.constitution = true; record.sourceDeviceID = record.to; record.sourceRoot = root
            record.constitutionRevision = record.revision + 1
        }
        if let brain {
            record.brain = brain; record.brainVerified = false
            record.brainRevision = record.revision + 1
            let source = dispatch.transferEvidence()
            if source.brainHealthy { record.sourcePages = source.pages }
            record.targetPages = evidence.pages
            if brain != .migrating {
                guard evidence.brainHealthy,
                      let pages = record.sourcePages, pages >= 0, evidence.pages == pages else {
                    throw fail("gbrain_health_or_page_count_mismatch")
                }
                if brain == .retained {
                    if let limitation = source.limitation ?? evidence.limitation { throw fail(limitation) }
                    guard source.brainHealthy else { throw fail("gbrain_old_host_unhealthy") }
                    guard ["ssh-stdio", "ssh-http"].contains(evidence.brainMode),
                          evidence.brainHostID == record.from else { throw fail("gbrain_old_host_not_verified") }
                } else {
                    guard ["pglite", "legacy"].contains(evidence.brainMode) else {
                        throw fail("gbrain_target_is_not_local")
                    }
                }
                record.brainVerified = true
            }
        }
        if release {
            if let signingName { record.signingName = signingName.trimmingCharacters(in: .whitespacesAndNewlines) }
            let source = dispatch.transferEvidence()
            let hasName = !record.signingName.isEmpty && source.signingNames.contains(record.signingName)
                && evidence.signingNames.contains(record.signingName)
            record.missingDependencies = evidence.missingDependencies
            record.releaseChecked = true
            record.releaseRevision = record.revision + 1
            record.release = !hasName ? .missingCertificate
                : evidence.missingDependencies.isEmpty ? .ready : .missingDependencies
        }
        record.revision += 1
        try save(record, dispatch: dispatch)
    }

    static func cancelPrepared(_ dispatch: DeviceDispatch) throws {
        var local = try dispatch.identity()
        guard local.role == .primary, let record = local.transfer,
              record.from == local.deviceID, !record.committed, record.previousTransferID == nil,
              local.epoch == record.oldEpoch else {
            throw fail("不可清除既有移交檢查點；請重試或由現任主設備正式移交回來")
        }
        local.transfer = nil; local.updatedAt = Date()
        try DeviceIdentityStore.forLocalDevice(entry: dispatch.entry, pairedDeviceID: local.deviceID).write(local)
    }

    static func accept(_ record: Record, bundle: DeviceDispatch.Bundle,
                       peer: DeviceRecord, dispatch: DeviceDispatch) throws -> DeviceDispatch.Receipt {
        let local = try dispatch.identity()
        try record.validate()
        let previous = local.transfer
        guard peer.id == record.from, bundle.sender == record.from,
              bundle.recipient == local.deviceID, record.from != record.to,
              bundle.epoch == (record.committed ? record.epoch : record.oldEpoch),
              record.participants.contains(local.deviceID), record.epoch > 0,
              record.oldEpoch == record.epoch - 1,
              dispatch.registry.list().contains(where: { $0.id == peer.id && $0.publicKeyFingerprint == peer.publicKeyFingerprint }),
              dispatch.registry.list().contains(where: { $0.id == record.to }) || local.deviceID == record.to
        else { throw fail("transfer_trust_or_hash_mismatch") }
        if record.constitution {
            guard bundle.files.isEmpty, bundle.hashes.isEmpty else { throw fail("transfer_metadata_only_after_source_switch") }
        } else {
            guard record.hashes == bundle.hashes else { throw fail("transfer_manifest_mismatch") }
        }
        // Freeze only until the source switch. Later GBrain/release checkpoints
        // must not overwrite or prohibit legitimate edits on the new primary.
        if previous?.id != record.id || previous?.constitution != true {
            guard record.hashes == (try dispatch.snapshot().mapValues(DeviceDispatch.hash)) else {
                throw fail("transfer_target_hash_mismatch")
            }
        }
        if record.constitution, local.deviceID == record.to, record.sourceRoot != dispatch.entry.root.path {
            throw fail("transfer_source_root_mismatch")
        }
        if previous?.id == record.id {
            guard record.revision >= previous!.revision, previous!.from == record.from, previous!.to == record.to,
                  previous!.epoch == record.epoch, previous!.hashes == record.hashes,
                  previous!.participants == record.participants,
                  !previous!.committed || record.committed,
                  !previous!.constitution || record.constitution,
                  Set(record.epochACKs).isSuperset(of: previous!.epochACKs) else { throw fail("transfer_replay") }
        } else {
            guard local.role == .secondary, local.primaryDeviceID == record.from,
                  local.epoch == record.oldEpoch else { throw fail("transfer_not_current_primary") }
        }
        guard local.epoch == record.oldEpoch || (previous?.id == record.id && local.epoch == record.epoch) else {
            throw fail("transfer_stale_epoch")
        }
        // A new primary must already trust every participant; pairing is never copied.
        if local.deviceID == record.to {
            let trusted = Set(dispatch.registry.list().map(\.id) + [local.deviceID])
            guard trusted.isSuperset(of: record.participants + [record.from]) else {
                throw fail("new_primary_missing_pairings")
            }
        }
        try save(record, dispatch: dispatch, commit: record.committed)
        return .init(seq: bundle.seq, phase: "converged", hashes: bundle.hashes, updated: Date(),
                     transfer: ACK(id: record.id, revision: record.revision, committed: record.committed,
                                   root: dispatch.entry.root.path, evidence: dispatch.transferEvidence()))
    }

    static func acknowledge(_ ack: ACK, sender: String, dispatch: DeviceDispatch) throws {
        let local = try dispatch.identity()
        guard var record = local.transfer, record.from == local.deviceID, record.id == ack.id,
              record.revision == ack.revision, record.participants.contains(sender),
              record.committed == ack.committed else { throw fail("transfer_ack_mismatch") }
        if sender == record.to {
            record.targetRoot = ack.root; record.targetEvidence = ack.evidence
            record.acknowledgedRevision = ack.revision
        }
        if !record.committed && sender == record.to {
            record.committed = true; record.revision += 1
            try save(record, dispatch: dispatch, commit: true)
            return
        }
        if record.committed && !record.epochACKs.contains(sender) {
            record.epochACKs.append(sender)
            record.revision += 1
        }
        try save(record, dispatch: dispatch)
    }

    static func evidence(entry: TatwoEntry) -> Evidence {
        var result = Evidence()
        // Read names only. No export, unlock, import, or key material access.
        if let (_, data) = try? DeviceDispatch.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) {
            result.signingNames = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                let parts = $0.components(separatedBy: "\""); return parts.count >= 3 ? parts[1] : nil
            }
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin",
               FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tatwo-build-deps/tmux/3.6a/bin").path]
        for tool in ["swift", "node", "npm", "git", "codesign", "xcrun", "hdiutil",
                     "python3", "curl", "tar", "ditto", "otool", "install_name_tool", "tmux"] {
            if !paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + tool) }) {
                result.missingDependencies.append(tool)
            }
        }
        if let tmux = paths.map({ $0 + "/tmux" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
           let (code, data) = try? DeviceDispatch.run(tmux, ["-V"]),
           code != 0 || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "tmux 3.6a" {
            result.missingDependencies.append("tmux 3.6a")
        }
        if (try? DeviceDispatch.run("/usr/bin/xcrun", ["--find", "swift"]).0) != 0 {
            result.missingDependencies.append("Swift toolchain")
        }
        for input in ["Package.swift", "scripts/build-app.sh", "scripts/bundle-gbrain.py",
                      "scripts/runtime-sign.py", "scripts/bundle-cli-runtime.sh",
                      "Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json"] {
            if !FileManager.default.fileExists(atPath: entry.repoRoot.appendingPathComponent(input).path) {
                result.missingDependencies.append(input)
            }
        }
        let health = GBrainHealth.read(entry: entry)
        result.brainHealthy = health.reason == nil
        if let data = try? DeviceDispatch.readFile("gbrain/state.json", root: entry.root),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.brainMode = state["mode"] as? String ?? "unconfigured"
            result.pages = state["pageCount"] as? Int
        }
        if let data = try? DeviceDispatch.readFile("gbrain/connection.json", root: entry.root),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.brainHostID = config["primaryID"] as? String
        }
        if let identity = try? DeviceIdentityStore.readLocal(entry: entry),
           (identity.role == .primary && ["ssh-stdio", "ssh-http"].contains(result.brainMode))
            || (identity.role == .secondary && ["pglite", "legacy"].contains(result.brainMode)) {
            result.limitation = "GBrain adapter 尚不支援主權與資料庫位置分離；須先完成相容性整合"
        }
        return result
    }
}
