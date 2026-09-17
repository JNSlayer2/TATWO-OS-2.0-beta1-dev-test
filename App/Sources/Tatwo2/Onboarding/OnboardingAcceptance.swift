import Foundation

extension SelfTest {
    static func onboardingChecks(root: URL) throws {
        let fm = FileManager.default
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw OSUpstreamBinding.failure("W82 " + label) }
            print("W82TEST PASS " + label)
        }
        func entry(_ home: URL) -> TatwoEntry {
            TatwoEntry(environment: [:], preference: nil, homeDirectory: home)
        }
        let home = root.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let bin = root.appendingPathComponent("fixture-bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["claude", "codex", "grok"] {
            let executable = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nprintf 'Fixture CLI 1.2\\n'\n".utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let scanned = OnboardingDiscovery.engines(home: home, environment: ["PATH": bin.path])
        try check(scanned.count == 3 && scanned.allSatisfy { $0.version == "Fixture CLI 1.2" },
                  "engine scan reads executable versions")
        try check(scanned.first(where: { $0.id == "grok" })?.target == nil,
                  "Grok unsupported path never guessed")
        let local = entry(home)
        var draft = OSOnboarding.Draft()
        draft.name = "Fixture workstation"
        draft.hardwareModel = "FixtureModel"
        draft.extraBoundaries = "Only synthetic data"
        let originals = [Data([0xEF, 0xBB, 0xBF]) + Data("custom rules\r\nno final newline".utf8),
                         Data("codex notes\n".utf8)]
        for (index, engine) in ["claude", "codex"].enumerated() {
            let relative = engine == "claude" ? ".claude/CLAUDE.md" : ".codex/AGENTS.md"
            let file = home.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originals[index].write(to: file)
            draft.engines.append(.init(id: engine, executable: "/fixture/" + engine, version: "fixture",
                target: .init(id: engine + "-cli", label: engine, path: file.path), selected: true))
        }
        try check(OSOnboarding.needsOnboarding(entry: local), "clean HOME requires onboarding")
        let plan = try OSOnboarding.preview(draft: draft, entry: local)
        try check(!local.exists && plan.targets.count == 2, "preview has no filesystem writes")
        try check(plan.targets.allSatisfy { $0.diff.contains("constitution-sha256") }, "W79 translator diff")
        try OSOnboarding.install(plan)
        try check(OSOnboarding.directories.allSatisfy {
            fm.fileExists(atPath: local.root.appendingPathComponent($0).path)
        }, "entrance structure created")
        let identity = try DeviceIdentityStore.readLocal(entry: local)
        try check(identity?.role == .primary && identity?.deviceID == draft.deviceID, "first device primary identity")
        try check(try Data(contentsOf: local.constitution) == Data(OSUpstreamBinding.bundled("os").utf8),
                  "primary bundled public v4")
        try check(!OSOnboarding.needsOnboarding(entry: local), "existing identity never reruns")
        let identityBefore = try Data(contentsOf: local.deviceJSON)
        try fm.removeItem(at: local.gbrainDir)
        try OSOnboarding.repairMissingDirectories(entry: local)
        try check(fm.fileExists(atPath: local.gbrainDir.path) && (try Data(contentsOf: local.deviceJSON)) == identityBefore,
                  "existing device only repairs missing directories")
        let notes = root.appendingPathComponent("existing-notes")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.removeItem(at: local.noteDir)
        try fm.createSymbolicLink(at: local.noteDir, withDestinationURL: notes)
        try OSOnboarding.repairMissingDirectories(entry: local)
        try check(try fm.destinationOfSymbolicLink(atPath: local.noteDir.path) == notes.path,
                  "existing directory links remain untouched")
        let store = try DeviceIdentityStore.forLocalDevice(entry: local)
        try store.write(store.read())
        let preserved = try JSONSerialization.jsonObject(with: Data(contentsOf: local.deviceJSON)) as! [String: Any]
        try check(preserved["preferences"] != nil && preserved["boundaries"] != nil && preserved["resources"] != nil,
                  "pairing updates preserve onboarding metadata")
        for item in plan.targets {
            try check(try OSUpstreamBinding.readText(item.target.path).contains(item.expectedBlock),
                      "external " + item.target.id + " managed block")
        }
        // Editing either live bytes or a backup must stop the whole removal batch.
        let first = URL(fileURLWithPath: plan.targets[0].target.path)
        let installed = try Data(contentsOf: first)
        try (installed + Data("\nuser edit".utf8)).write(to: first)
        do {
            try ManagedRulesRemoval.remove(entry: local)
            throw OSUpstreamBinding.failure("W82 accepted changed live file")
        } catch {
            try check(try Data(contentsOf: first) == installed + Data("\nuser edit".utf8), "removal preserves user edits")
        }
        try installed.write(to: first)
        let records = try JSONDecoder().decode([ManagedRulesRemoval.Record].self,
                                               from: Data(contentsOf: ManagedRulesRemoval.manifest(local)))
        let backup = ManagedRulesRemoval.manifest(local).deletingLastPathComponent()
            .appendingPathComponent(records[0].backup!)
        let backupBytes = try Data(contentsOf: backup)
        try Data("tampered backup".utf8).write(to: backup)
        var backupRejected = false
        do { try ManagedRulesRemoval.remove(entry: local) } catch { backupRejected = true }
        try check(backupRejected && (try Data(contentsOf: first)) == installed, "tampered backup fails before removal")
        try backupBytes.write(to: backup)
        var changedIdentity = try store.read()
        changedIdentity.name = "Renamed fixture"
        try store.write(changedIdentity)
        let bindingEnvironment = OSOnboarding.bindingEnvironment(entry: local, targets: plan.targets.map(\.target))
        let runtime = local.root.appendingPathComponent("os-upstream.md")
        try Data(RuleGenerator.generate(environment: bindingEnvironment, runtimePath: runtime.path).utf8).write(to: runtime)
        let updated = OSUpstreamBinding.apply(OSUpstreamBinding.preview(environment: bindingEnvironment),
                                              environment: bindingEnvironment)
        try check(updated.failure == nil && updated.modified.count == 2, "W79 can regenerate installed blocks")
        try ManagedRulesRemoval.remove(entry: local)
        for (index, item) in plan.targets.enumerated() {
            try check(try RuleGenerator.hash(Data(contentsOf: URL(fileURLWithPath: item.target.path))) ==
                      RuleGenerator.hash(originals[index]), "remove restores original hash " + item.target.id)
        }
        try ManagedRulesRemoval.remove(entry: local)
        try check(true, "removal is idempotent")

        let secondaryHome = root.appendingPathComponent("secondary-home")
        try fm.createDirectory(at: secondaryHome, withIntermediateDirectories: true)
        let secondary = entry(secondaryHome)
        var secondaryDraft = OSOnboarding.Draft()
        secondaryDraft.name = "Fixture companion"
        secondaryDraft.role = .secondary
        let secondaryPlan = try OSOnboarding.preview(draft: secondaryDraft, entry: secondary)
        try check(secondaryPlan.text.contains(OSOnboarding.waiting), "secondary waiting state")
        try OSOnboarding.install(secondaryPlan)
        try check(!fm.fileExists(atPath: secondary.constitution.path) &&
                  !fm.fileExists(atPath: secondary.skillet.path) &&
                  !fm.fileExists(atPath: secondary.gbrainDir.appendingPathComponent("brain").path),
                  "secondary creates neither constitution nor database")
        try check((try DeviceIdentityStore.readLocal(entry: secondary))?.role == .secondary,
                  "secondary identity persists")

        let staleHome = root.appendingPathComponent("stale-home")
        try fm.createDirectory(at: staleHome, withIntermediateDirectories: true)
        let stale = entry(staleHome)
        var staleDraft = draft
        staleDraft.deviceID = UUID().uuidString.lowercased()
        let stalePlan = try OSOnboarding.preview(draft: staleDraft, entry: stale)
        try Data("changed after preview".utf8).write(to: first)
        var rejected = false
        do { try OSOnboarding.install(stalePlan) } catch { rejected = true }
        try check(rejected && !stale.exists, "stale preview fails before entrance write")

        // New engine files disappear again rather than leaving empty global rule files.
        let newHome = root.appendingPathComponent("new-home")
        try fm.createDirectory(at: newHome, withIntermediateDirectories: true)
        let newEntry = entry(newHome)
        var newDraft = OSOnboarding.Draft()
        let newPath = newHome.appendingPathComponent(".codex/AGENTS.md").path
        newDraft.engines = [.init(id: "codex", executable: "/fixture/codex", version: "fixture",
            target: .init(id: "codex-cli", label: "codex", path: newPath), selected: true)]
        try OSOnboarding.install(OSOnboarding.preview(draft: newDraft, entry: newEntry))
        try ManagedRulesRemoval.remove(entry: newEntry)
        try check(!fm.fileExists(atPath: newPath), "new rule file removal restores absence")

        let externalHome = root.appendingPathComponent("external-home")
        try fm.createDirectory(at: externalHome, withIntermediateDirectories: true)
        let externalEntry = entry(externalHome)
        var externalDraft = OSOnboarding.Draft()
        externalDraft.physicalRoot = root.appendingPathComponent("synthetic-volume/AI/TATWO OS")
        try OSOnboarding.install(OSOnboarding.preview(draft: externalDraft, entry: externalEntry))
        try check(try fm.destinationOfSymbolicLink(atPath: externalEntry.root.path) ==
                  externalDraft.physicalRoot!.path, "external volume retains canonical entrance symlink")
        try check((try DeviceIdentityStore.readLocal(entry: externalEntry))?.role == .primary,
                  "external volume identity resolves")
        let mounted = root.appendingPathComponent("mounted-fixture")
        try fm.createDirectory(at: mounted, withIntermediateDirectories: true)
        let unpluggedEntry = entry(root.appendingPathComponent("unplugged-home"))
        var unpluggedDraft = OSOnboarding.Draft()
        unpluggedDraft.physicalRoot = mounted.appendingPathComponent("AI/TATWO OS")
        let unpluggedPlan = try OSOnboarding.preview(draft: unpluggedDraft, entry: unpluggedEntry)
        try fm.moveItem(at: mounted, to: root.appendingPathComponent("unmounted-fixture"))
        var unpluggedRejected = false
        do { try OSOnboarding.install(unpluggedPlan) } catch { unpluggedRejected = true }
        try check(unpluggedRejected && !unpluggedEntry.exists && !fm.fileExists(atPath: mounted.path),
                  "unplugged volume never falls back to system disk")

        let failureHome = root.appendingPathComponent("failure-home")
        try fm.createDirectory(at: failureHome, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: failureHome.appendingPathComponent(".codex"))
        let failureEntry = entry(failureHome)
        var failureDraft = OSOnboarding.Draft()
        failureDraft.engines = [.init(id: "codex", executable: "/fixture/codex", version: "fixture",
            target: .init(id: "codex-cli", label: "codex",
                          path: failureHome.appendingPathComponent(".codex/AGENTS.md").path), selected: true)]
        var failed = false
        do { try OSOnboarding.install(OSOnboarding.preview(draft: failureDraft, entry: failureEntry)) }
        catch { failed = true }
        try check(failed && !fm.fileExists(atPath: failureEntry.deviceJSON.path) &&
                  !fm.fileExists(atPath: failureEntry.constitution.path),
                  "failed install rolls back identity and sources")

        let live = root.appendingPathComponent("registry")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        let primary = DeviceRecord(id: draft.deviceID, name: "Fixture primary", host: "fixture.invalid",
            user: "fixture", sshPort: 22, publicKeyFingerprint: "fixture",
            addedAt: Date(), lastSeenAt: Date(), workdirMap: [:], role: .primary, epoch: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([primary]).write(to: live.appendingPathComponent("devices.json"))
        try check(OSOnboarding.defaultDraft(environment: ["TATWO2_LIVE_ROOT": live.path]).role == .secondary,
                  "paired primary defaults to secondary")
        var takeover = OSOnboarding.defaultDraft(environment: ["TATWO2_LIVE_ROOT": live.path])
        takeover.role = .primary
        var takeoverRejected = false
        do { _ = try OSOnboarding.preview(draft: takeover, entry: failureEntry) }
        catch { takeoverRejected = true }
        try check(takeoverRejected, "paired primary cannot be superseded by onboarding")
        print("W82TEST ROOT " + local.root.path)
    }
}
