import Foundation
import Darwin

/// App-owned first-run transaction. Preview is read-only; installers never call this.
enum OSOnboarding {
    private static let installLock = NSLock()
    static let directories = ["gbrain", "rooms", "staging", "archive", "note"]
    static let waiting = "等待主設備派發"

    struct Draft {
        var deviceID = UUID().uuidString.lowercased()
        var name = Host.current().localizedName ?? "我的 Mac"
        var hardwareModel = (try? DeviceIdentityStore.hardwareModel()) ?? "—"
        var role: DeviceRole = .primary
        var primary: DeviceRecord?
        var hasPairedPrimary = false
        var physicalRoot: URL?
        var engines: [Engine] = []
        var energy = "平衡"
        var updateChannel = "stable"
        var allowsRemoteWork = false
        var extraBoundaries = ""
        var boundaries: [String] {
            (role == .secondary ? ["不發版", "不推公開倉", "不手改憲法副本", "不推整合分支"] : []) +
            extraBoundaries.split(separator: "\n").map(String.init)
        }
    }

    struct Engine: Identifiable {
        let id: String
        let executable: String
        let version: String
        let target: UpstreamBindingTarget?
        var selected: Bool
    }

    struct TargetSnapshot {
        let target: UpstreamBindingTarget
        let original: Data?
        let expectedBlock: String
        let diff: String
    }

    struct Preview {
        let entry: TatwoEntry
        let resolvedEntry: URL
        let physicalRoot: URL?
        let physicalAnchor: PhysicalAnchor?
        let identity: Data
        let constitution: Data?
        let skillet: Data?
        let originalConstitution: Data?
        let originalSkillet: Data?
        let upstream: String?
        let targets: [TargetSnapshot]
        var text: String {
            let files = ["device.json"] + directories +
                (constitution == nil ? [] : ["os.md"]) + (skillet == nil ? [] : ["skillet.md"])
            return "入口：\(entry.root.path)\n" +
                (physicalRoot.map { "實體位置：\($0.path)（入口為符號連結）\n" } ?? "") +
                files.map { "+ " + $0 }.joined(separator: "\n") +
                "\n\n" + String(decoding: identity, as: UTF8.self) +
                (upstream == nil ? "\n\n\(waiting)；收到可信副本後才產生引擎規則。" : "") +
                targets.map { "\n\n\($0.target.path)\n\($0.diff)" }.joined()
        }
    }

    struct PhysicalAnchor {
        let url: URL
        let device: Int32
        let inode: UInt64

        init(destination: URL) throws {
            var parent = destination.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
            url = DeviceIdentityStore.canonical(parent)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw OSUpstreamBinding.failure("外接卷不可用")
            }
            device = info.st_dev
            inode = info.st_ino
        }

        func validate() throws {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_dev == device, info.st_ino == inode else {
                throw OSUpstreamBinding.failure("外接卷在預覽後已卸載或改變；請重新選擇，不改寫系統碟")
            }
        }
    }

    static func needsOnboarding(entry: TatwoEntry) -> Bool {
        !entry.exists || !FileManager.default.fileExists(atPath: entry.deviceJSON.path)
    }

    /// Existing devices only get missing directories. Never regenerate identity or sources.
    static func repairMissingDirectories(entry: TatwoEntry) throws {
        guard entry.exists, try DeviceIdentityStore.readLocal(entry: entry) != nil else { return }
        let fm = FileManager.default
        for name in directories {
            let url = entry.root.appendingPathComponent(name)
            var directory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                // Existing devices may intentionally link a directory to another volume.
                // Do not move, chmod or traverse that directory while repairing the entrance.
                continue
            }
            guard (try? fm.attributesOfItem(atPath: url.path)) == nil else {
                throw OSUpstreamBinding.failure("入口子目錄不可用，保留原狀：" + name)
            }
            try fm.createDirectory(at: url, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    static func defaultDraft(environment: [String: String]) -> Draft {
        var draft = Draft()
        let primaries = DeviceStatusReader.registry(environment: environment).filter { $0.role == .primary }
        // An ambiguous registry is not permission to establish a new sovereign.
        if !primaries.isEmpty { draft.role = .secondary; draft.hasPairedPrimary = true }
        if primaries.count == 1 { draft.primary = primaries[0] }
        return draft
    }

    static func readOptional(_ url: URL) throws -> Data? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path),
           (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil { return nil }
        _ = try OSUpstreamBinding.readText(url.path) // bounded, UTF-8, regular file only
        return try Data(contentsOf: url)
    }

    static func preview(draft: Draft, entry: TatwoEntry) throws -> Preview {
        guard needsOnboarding(entry: entry), entry.status == .missing || entry.status == .available else {
            throw OSUpstreamBinding.failure("入口已接入、不是資料夾或連結已失效；不覆寫")
        }
        if (draft.hasPairedPrimary || draft.primary != nil) && draft.role == .primary {
            throw OSUpstreamBinding.failure("已有配對主設備；請使用正式主權移交流程")
        }
        if let physical = draft.physicalRoot {
            guard entry.status == .missing, physical.path.hasPrefix("/"),
                  physical.standardizedFileURL != entry.root.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: physical.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: physical.path)) == nil else {
                throw OSUpstreamBinding.failure("外接卷入口必須是尚不存在的新目錄；不搬動既有入口")
            }
        }
        let originalConstitution = try readOptional(entry.constitution)
        let originalSkillet = try readOptional(entry.skillet)
        let constitution = draft.role == .primary
            ? try originalConstitution ?? Data(OSUpstreamBinding.bundled("os").utf8) : nil
        let skillet = draft.role == .primary
            ? originalSkillet ?? Data("# 常用技能\n\n本檔只補充做法，不修改或放寬 os.md。\n".utf8) : nil
        let identity = DeviceIdentity(
            deviceID: draft.deviceID, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            hardwareModel: draft.hardwareModel, role: draft.role,
            epoch: draft.role == .primary ? 1 : draft.primary?.epoch,
            primaryDeviceID: draft.role == .primary ? draft.deviceID :
                (draft.primary?.epoch == nil ? nil : draft.primary?.id),
            updatedAt: Date())
        var object = try JSONSerialization.jsonObject(with: identity.encoded()) as! [String: Any]
        object["boundaries"] = draft.boundaries
        object["preferences"] = ["energy": draft.energy, "updateChannel": draft.updateChannel,
                                 "allowsRemoteWork": draft.allowsRemoteWork]
        object["resources"] = ["entry": entry.root.path,
                               "physicalEntry": draft.physicalRoot?.path ?? entry.root.path,
                               "staging": entry.root.appendingPathComponent("staging").path]
        object["managedEngines"] = draft.engines.filter(\.selected).map(\.id)
        let identityData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        var upstream: String?
        var targets: [TargetSnapshot] = []
        // A secondary never treats an unverified existing file as a dispatched source.
        if let constitution {
            let source = RuleGenerator.Sources(
                constitution: String(decoding: constitution, as: UTF8.self),
                constitutionHash: RuleGenerator.hash(constitution), identityHash: RuleGenerator.hash(identityData),
                identity: identity, primaryName: identity.name,
                boundaries: draft.boundaries.joined(separator: "\n"), root: entry.root.path)
            let runtime = entry.root.appendingPathComponent("os-upstream.md").path
            upstream = try RuleGenerator.generate(source: source, runtimePath: runtime)
            for engine in draft.engines where engine.selected {
                guard let target = engine.target else { continue }
                let original = try readOptional(URL(fileURLWithPath: target.path))
                let oldText = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
                // Do not take over previously managed/manual blocks during first-run.
                guard try OSUpstreamBinding.blockRange(oldText) == nil else {
                    throw OSUpstreamBinding.failure("已有 OS 管理區塊，請在設定中檢視：" + target.path)
                }
                let block = try RuleTranslators.translator(for: target.id).managedBlock(
                    source: source, runtimePath: runtime,
                    hash: String(OSUpstreamBinding.digest(upstream!).prefix(12)))
                targets.append(.init(target: target, original: original, expectedBlock: block,
                                     diff: block.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")))
            }
        }
        return Preview(entry: entry, resolvedEntry: DeviceIdentityStore.canonical(entry.root),
                       physicalRoot: draft.physicalRoot,
                       physicalAnchor: try draft.physicalRoot.map { try PhysicalAnchor(destination: $0) },
                       identity: identityData,
                       constitution: constitution, skillet: skillet,
                       originalConstitution: originalConstitution, originalSkillet: originalSkillet,
                       upstream: upstream, targets: targets)
    }

    private static func createDirectories(entry: TatwoEntry) throws {
        for name in directories {
            let url = entry.root.appendingPathComponent(name)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               attrs[.type] as? FileAttributeType != .typeDirectory {
                throw OSUpstreamBinding.failure("入口子目錄不是一般資料夾：" + name)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// Snapshot revalidation happens before the first write. Identity is the completion marker.
    static func install(_ plan: Preview) throws {
        guard installLock.try() else { throw OSUpstreamBinding.failure("另一個視窗正在接入；請稍候") }
        defer { installLock.unlock() }
        let fm = FileManager.default, entry = plan.entry
        guard DeviceIdentityStore.canonical(entry.root) == plan.resolvedEntry,
              needsOnboarding(entry: entry),
              try readOptional(entry.deviceJSON) == nil,
              try readOptional(entry.constitution) == plan.originalConstitution,
              try readOptional(entry.skillet) == plan.originalSkillet else {
            throw OSUpstreamBinding.failure("入口在預覽後已變更，請重新預覽")
        }
        for target in plan.targets {
            guard try readOptional(URL(fileURLWithPath: target.target.path)) == target.original else {
                throw OSUpstreamBinding.failure("引擎檔在預覽後已變更，請重新預覽")
            }
        }
        // Runtime is also user-owned if it already exists. Never silently replace it.
        if plan.upstream != nil, try readOptional(entry.root.appendingPathComponent("os-upstream.md")) != nil {
            throw OSUpstreamBinding.failure("入口已有執行期上游，請先在設定中處理")
        }
        if let physical = plan.physicalRoot {
            try plan.physicalAnchor?.validate()
            guard entry.status == .missing, !fm.fileExists(atPath: physical.path) else {
                throw OSUpstreamBinding.failure("外接卷路徑已改變")
            }
            try fm.createDirectory(at: physical, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: entry.root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: entry.root, withDestinationURL: physical)
        }
        try createDirectories(entry: entry)
        var created: [(URL, Data)] = []
        func writeNew(_ data: Data, _ url: URL) throws {
            try data.write(to: url, options: .withoutOverwriting)
            created.append((url, data))
        }
        do {
            if let data = plan.constitution, plan.originalConstitution == nil { try writeNew(data, entry.constitution) }
            if let data = plan.skillet, plan.originalSkillet == nil { try writeNew(data, entry.skillet) }
            if let text = plan.upstream { try writeNew(Data(text.utf8), entry.root.appendingPathComponent("os-upstream.md")) }
            // W79 reads identity while translating. Roll back this marker if a later step fails.
            try writeNew(plan.identity, entry.deviceJSON)
            if !plan.targets.isEmpty {
                for item in plan.targets {
                    try fm.createDirectory(atPath: (item.target.path as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
                let env = bindingEnvironment(entry: entry, targets: plan.targets.map(\.target))
                RuleGenerator.configure(environment: env)
                let binding = OSUpstreamBinding.preview(environment: env)
                guard binding.error == nil, binding.items.count == plan.targets.count,
                      zip(binding.items, plan.targets).allSatisfy({
                          $0.original.map { Data($0.utf8) } == $1.original &&
                          $0.expectedHash == OSUpstreamBinding.digest($1.expectedBlock)
                      }) else { throw OSUpstreamBinding.failure("轉譯預覽已改變，停止接入") }
                try ManagedRulesRemoval.saveBaseline(plan.targets, entry: entry)
                let result = OSUpstreamBinding.apply(binding, environment: env)
                if let failure = result.failure { throw OSUpstreamBinding.failure(failure) }
            }
        } catch {
            // Only restore files whose installed hash still matches our own write.
            var recoveryError: Error?
            if fm.fileExists(atPath: ManagedRulesRemoval.manifest(entry).path) {
                do { try ManagedRulesRemoval.remove(entry: entry) } catch { recoveryError = error }
            }
            for (url, data) in created.reversed() {
                do {
                    guard try readOptional(url) == data else {
                        throw OSUpstreamBinding.failure("接入期間檔案已修改，保留：" + url.path)
                    }
                    try fm.removeItem(at: url)
                } catch { recoveryError = error }
            }
            if let recoveryError {
                throw OSUpstreamBinding.failure("接入失敗：\(error.localizedDescription)\n回復需人工檢查：\(recoveryError.localizedDescription)")
            }
            throw error
        }
    }

    static func bindingEnvironment(entry: TatwoEntry, targets: [UpstreamBindingTarget]) -> [String: String] {
        ["TATWO2_OS_ROOT": entry.root.path, "TATWO2_OS_UPSTREAM_PATH": entry.root.appendingPathComponent("os-upstream.md").path,
         "TATWO2_BIND_TARGETS": targets.map { $0.id + "=" + $0.path }.joined(separator: ",")]
    }
}
