import AppKit
import SwiftUI
import CryptoKit

enum OSUpstream { static let overridePath = "unused-fixture" }
@MainActor enum IslandExceptionsNavigation {
    static var shell: Shell?
    final class Shell { func holdOpen(_ value: Bool) {} }
}

@main struct OSUpstreamUpdateChecks {
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic) }
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let scenario = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let runtime = root.appendingPathComponent("os-upstream.md")
        let bundle = root.appendingPathComponent("bundle.md")
        let marker = root.appendingPathComponent("os-upstream.installed.sha256")
        let notice = root.appendingPathComponent("os-upstream.update-available.md")
        let fm = FileManager.default
        let old = "# Rules\nKeep custom preferences\n\n"
        let new = "# Rules\nRead the current upstream\n\n"
        try write(old, runtime)
        try write(new, bundle)
        func refresh() -> OSUpstreamRefresh.Outcome {
            OSUpstreamRefresh.applyOnLaunch(runtimePath: runtime.path, bundled: bundle, now: Date(timeIntervalSince1970: 0))
        }
        func pending() throws -> OSUpstreamRefresh.PendingUpdate {
            guard let result = try OSUpstreamRefresh.pendingUpdate(runtimePath: runtime.path, bundled: bundle) else {
                throw Failure(message: "missing pending difference")
            }
            return result
        }
        func model() -> OSUpstreamUpdateModel {
            OSUpstreamUpdateModel(runtimePath: runtime.path, bundled: bundle)
        }
        func checkHidden() throws {
            try check(OSUpstreamRefresh.pendingUpdate(runtimePath: runtime.path, bundled: bundle) == nil, "pending should be nil")
            try check(!fm.fileExists(atPath: notice.path), "stale notice")
        }
        switch scenario {
        case "managed":
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.path)
            try write(hash(old) + "\n", marker)
            guard case .updated(let backup) = refresh() else { throw Failure(message: "did not auto-update") }
            try check(text(URL(fileURLWithPath: backup)) == old, "backup preimage")
            try check((fm.attributesOfItem(atPath: backup)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      "backup broadened private runtime read access")
            try check(text(runtime) == new && text(marker) == hash(new) + "\n", "content/marker not advanced")
            try check(URL(fileURLWithPath: backup).lastPathComponent == "os-upstream.md.bak-19700101T000000000Z", "backup name")
            try checkHidden()
        case "custom", "unmarked", "empty-marker":
            if scenario == "custom" { try write(hash("other rules") + "\n", marker) }
            if scenario == "empty-marker" { try write("", marker) }
            let originalMarker = try? Data(contentsOf: marker)
            try check(refresh() == .keptUserEdited, "unsafe automatic update")
            try check(text(runtime) == old && (try? Data(contentsOf: marker)) == originalMarker, "custom data mutated")
            try check(text(notice).contains("設定 › OS"), "no visible notice")
            try check(pending().runtimeText == old, "wrong runtime comparison")
        case "equal-unmarked":
            try write(old, bundle)
            try check(refresh() == .unchanged, "same content")
            try checkHidden()
            try check(!fm.fileExists(atPath: marker.path), "silently adopted unmarked runtime")
            try write(new, bundle)
            try check(refresh() == .keptUserEdited && text(runtime) == old, "later update adopted ownership")
        case "backup-failure":
            try write(hash(old), marker)
            let backup = root.appendingPathComponent("os-upstream.md.bak-19700101T000000000Z")
            try write("existing backup must survive", backup)
            guard case .failed = refresh() else { throw Failure(message: "backup collision not rejected") }
            try check(text(runtime) == old && text(marker) == hash(old), "write occurred without backup")
            try check(text(backup) == "existing backup must survive", "backup overwritten")
        case "symlink-backup":
            let target = root.appendingPathComponent("custom-target.md")
            // Move the fixture rather than deleting it to make room for the link.
            try fm.moveItem(at: runtime, to: target)
            try fm.createSymbolicLink(at: runtime, withDestinationURL: target)
            let result = try OSUpstreamRefresh.applyBundledVersion(pending(), runtimePath: runtime.path, bundled: bundle)
            guard case .updated(let backup) = result else { throw Failure(message: "symlink apply failed") }
            try write("target changed later", target)
            try check(text(URL(fileURLWithPath: backup)) == old, "backup merely copied a symlink")
            try check(text(runtime) == new, "runtime not updated")
        case "write-failure":
            let reviewed = try pending()
            try fm.setAttributes([.immutable: true], ofItemAtPath: runtime.path)
            defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: runtime.path) }
            do {
                _ = try OSUpstreamRefresh.applyBundledVersion(reviewed, runtimePath: runtime.path, bundled: bundle)
                throw Failure(message: "immutable runtime unexpectedly replaced")
            } catch is Failure { throw Failure(message: "immutable runtime unexpectedly replaced") }
            catch {}
            try check(text(runtime) == old, "failed write altered runtime")
            try check((try? text(marker)) != hash(old) + "\n", "failed write claimed custom ownership")
            try check(refresh() == .keptUserEdited, "failed manual apply allowed automatic overwrite")
        case "dangling-link":
            try fm.moveItem(at: runtime, to: root.appendingPathComponent("original.md"))
            let target = root.appendingPathComponent("missing-target.md")
            try fm.createSymbolicLink(at: runtime, withDestinationURL: target)
            try check(refresh() == .failed("runtime_symlink_unreadable"), "dangling link overwritten")
            try check(fm.destinationOfSymbolicLink(atPath: runtime.path) == target.path, "dangling link not preserved")
            try check(!fm.fileExists(atPath: marker.path), "dangling link acquired marker")
        case "keep", "changed-choice":
            try check(refresh() == .keptUserEdited, "expected prompt")
            let first = model()
            first.reload()
            try check(first.keepCustom(pending()), "keep failed")
            try check(refresh() == .keptUserEdited && text(runtime) == old, "keep changed runtime")
            try checkHidden()
            let reopened = model()
            reopened.reload(notify: true)
            try check(reopened.pending == nil, "choice was only in memory")
            try check(!fm.fileExists(atPath: marker.path), "keep claimed system ownership")
            if scenario == "changed-choice" {
                try write(new + "App revision\n", bundle)
                try check(refresh() == .keptUserEdited && fm.fileExists(atPath: notice.path), "changed bundle not prompted")
                try check(reopened.keepCustom(pending()), "second keep failed")
                try write(old + "Custom revision\n", runtime)
                try check(refresh() == .keptUserEdited && fm.fileExists(atPath: notice.path), "changed runtime not prompted")
                try check(pending().runtimeText == old + "Custom revision\n", "new preview missing")
            }
        case "apply":
            _ = refresh()
            let result = try OSUpstreamRefresh.applyBundledVersion(pending(), runtimePath: runtime.path, bundled: bundle,
                                                                  now: Date(timeIntervalSince1970: 0))
            guard case .updated(let backup) = result else { throw Failure(message: "apply not updated") }
            try check(text(URL(fileURLWithPath: backup)) == old, "apply did not back up")
            try check(text(runtime) == new && text(marker) == hash(new) + "\n", "apply did not manage version")
            try checkHidden()
        case "corrupt-choice":
            try Data([0xff]).write(to: root.appendingPathComponent("os-upstream.kept-custom.sha256"))
            try check(refresh() == .keptUserEdited && text(runtime) == old, "invalid receipt granted ownership")
            let store = model()
            store.reload()
            try check(store.pending != nil && store.error == nil, "invalid receipt hid actionable diff")
        case "stale-runtime", "stale-bundle":
            let reviewed = try pending()
            let changed = scenario == "stale-runtime" ? runtime : bundle
            try write("external edit\n", changed)
            let store = model()
            try check(!store.applyBundled(reviewed), "stale apply accepted")
            try check(!store.keepCustom(reviewed), "stale keep accepted")
            try check(store.error?.contains("內容已變更") == true, "missing stale warning")
            try check(text(runtime) == (scenario == "stale-runtime" ? "external edit\n" : old), "stale preview overwrote edit")
            try check(!fm.fileExists(atPath: marker.path), "stale preview wrote marker")
        case "diff":
            for (before, after) in [("a\nold\nz\n", "a\nnew\nz\n"), ("", "a"), ("a", ""), ("a\n", "a"),
                                    ("x\nx\nz", "x\nz\nx"), ("a\r\n", "a\n"), ("\n\n", "\n"), ("é", "e\u{301}")] {
                let rows = OSUpstreamLineDiff.lines(runtime: before, bundled: after)
                try check(rows.filter { $0.kind != .added }.map(\.text).joined(separator: "\n") == before, "old reconstruction")
                try check(rows.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n") == after, "new reconstruction")
                try check(rows.contains { $0.kind != .context }, "changed lines invisible")
            }
            let rows = OSUpstreamLineDiff.lines(runtime: "same\nold\nlast", bundled: "same\nnew\nlast")
            try check(rows.map(\.kind) == [.context, .removed, .added, .context], "not a contextual line diff")
            try check(rows[1].runtimeLine == 2 && rows[2].bundledLine == 2, "incorrect line numbers")
        case "ui":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let store = model()
            IslandNotice.shared.hostAvailable = false
            store.reload(notify: true)
            try check(IslandNotice.shared.current == nil, "notice sent without host")
            IslandNotice.shared.hostAvailable = true
            store.reload(notify: true)
            let shown = IslandNotice.shared.current
            try check(shown?.title == "OS 上游有更新" && (shown?.title.count ?? 99) <= 14, "wrong Island title")
            store.reload(notify: true)
            try check(IslandNotice.shared.current?.id == shown?.id, "duplicate Island notice")
            if let shown { IslandNotice.shared.resolve(.cancel, id: shown.id) }
            try check(IslandNotice.shared.current == nil, "duplicate queued notice")
            try renderRow(store, root: root, captureName: "pending", exists: true)
            let reviewed = try pending()
            try render(OSUpstreamDiffSheet(pending: reviewed, error: nil,
                       apply: {}, keep: {}, close: {}), root: root, captureName: "diff", size: NSSize(width: 760, height: 560))
            try check(store.keepCustom(reviewed), "UI keep not wired")
            try renderRow(store, root: root, captureName: "kept", exists: false)
            try write(old, bundle)
            store.reload()
            try renderRow(store, root: root, captureName: "equal", exists: false)
            try write(new + "next\n", bundle)
            store.reload()
            try renderRow(store, root: root, captureName: "next", exists: true)
            try check(store.applyBundled(pending()), "UI apply not wired")
            try renderRow(store, root: root, captureName: "applied", exists: false)
        case "ui-actions":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let store = model()
            store.reload()
            for keep in [true, false] {
                if !keep {
                    try write(new + "next update\n", bundle)
                    store.reload()
                }
                let name = keep ? "click-keep" : "click-apply"
                try render(OSUpstreamUpdateView(update: store), root: root, captureName: name,
                           size: NSSize(width: 780, height: 560)) { host in
                    guard let window = host.window else { throw Failure(message: "missing parent window") }
                    click(window, point: NSPoint(x: 180, y: 560 - 28))
                    try pump { window.attachedSheet != nil }
                    guard let sheet = window.attachedSheet, let content = sheet.contentView else {
                        throw Failure(message: "row did not open diff")
                    }
                    try snapshot(content, root: root, captureName: name + "-sheet", size: content.bounds.size)
                    // Coordinates are local to this synthetic native sheet,
                    // whose fresh snapshot is retained immediately before the action.
                    click(sheet, point: NSPoint(x: keep ? 80 : content.bounds.width - 95, y: 32))
                    try pump { window.attachedSheet == nil && store.pending == nil }
                    try check(store.error == nil, "sheet action failed")
                }
                try renderRow(store, root: root, captureName: name + "-resolved", exists: false)
                try check(text(runtime) == (keep ? old : new + "next update\n"), "sheet action did not persist content")
            }
        case "ui-stale":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            let store = model()
            store.reload()
            try render(OSUpstreamUpdateView(update: store), root: root, captureName: "stale-row",
                       size: NSSize(width: 780, height: 560)) { host in
                guard let window = host.window else { throw Failure(message: "missing parent window") }
                click(window, point: NSPoint(x: 180, y: 560 - 28))
                try pump { window.attachedSheet != nil }
                guard let sheet = window.attachedSheet, let content = sheet.contentView else {
                    throw Failure(message: "missing review sheet")
                }
                let external = old + "external edit after preview\n"
                try write(external, runtime)
                click(sheet, point: NSPoint(x: content.bounds.width - 95, y: 32))
                try pump { store.error != nil && store.pending?.runtimeText == external }
                try check(text(runtime) == external, "stale native apply overwrote external edit")
                // SwiftUI replaces the sheet's item with the refreshed content pair.
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let refreshed = window.attachedSheet, let refreshedContent = refreshed.contentView else {
                    throw Failure(message: "stale review did not stay actionable")
                }
                try snapshot(refreshedContent, root: root, captureName: "stale-refreshed-sheet",
                             size: refreshedContent.bounds.size)
                click(refreshed, point: NSPoint(x: 80, y: 32))
                try pump { window.attachedSheet == nil && store.pending == nil }
                try check(store.error == nil && text(runtime) == external, "refreshed keep did not preserve edit")
                store.reload()
                try check(store.pending == nil, "refreshed choice was not persisted")
            }
        default: throw Failure(message: "unknown scenario")
        }
        print("W68 PASS \(scenario)")
    }

    @MainActor static func click(_ window: NSWindow, point: NSPoint) {
        let content = window.contentView
        let local = content?.isFlipped == true
            ? NSPoint(x: point.x, y: (content?.bounds.height ?? 0) - point.y) : point
        let location = content?.convert(local, to: nil) ?? point
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    @MainActor static func pump(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(condition(), "native UI action timed out")
    }

    @MainActor static func renderRow(_ model: OSUpstreamUpdateModel, root: URL, captureName name: String, exists: Bool) throws {
        try render(OSUpstreamUpdateView(update: model), root: root, captureName: name, size: NSSize(width: 568, height: 110)) { host in
            // Check actual native pixels, not merely the model's pending flag:
            // absent row/error must render a completely empty settings surface.
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
                  let bytes = bitmap.bitmapData else { throw Failure(message: "missing row pixels") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let pixelSize = bitmap.bitsPerPixel / 8
            var hasContent = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    for c in 0..<pixelSize where bytes[y * bitmap.bytesPerRow + x * pixelSize + c] != bytes[c] {
                        hasContent = true
                    }
                }
            }
            try check(hasContent == exists, "\(name): actual settings row content should exist=\(exists)")
        }
    }

    @MainActor static func render<V: View>(_ view: V, root: URL, captureName name: String, size: NSSize,
                                          inspect: (NSView) throws -> Void = { _ in }) throws {
        let host = NSHostingView(rootView: view.padding(20).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        try snapshot(host, root: root, captureName: name, size: size)
        try inspect(host)
    }

    @MainActor static func snapshot(_ host: NSView, root: URL, captureName name: String, size: NSSize) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let data = { host.cacheDisplay(in: host.bounds, to: bitmap); return bitmap.representation(using: .png, properties: [:]) }()
        else { throw Failure(message: "native screenshot unavailable") }
        let image = root.appendingPathComponent(name + ".png")
        try data.write(to: image)
        let receipt: [String: Any] = ["surface": "Settings OS upstream \(name)", "path": image.path,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "runID": root.lastPathComponent,
            "width": size.width, "height": size.height,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name + ".json"))
    }
}
