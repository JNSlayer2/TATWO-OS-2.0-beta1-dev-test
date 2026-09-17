import CryptoKit
import Foundation

/// Wire values only. No registry/store initializers, document projection, migration or save.
struct DeviceStatusField<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value?
    var acquiredAt: Date
    var reason: String?
}

struct DeviceStatusFile: Codable, Sendable {
    var sha256: String
    var text: String?
}

struct DeviceStatusCode: Codable, Sendable {
    var integrationCommit: String
    var head: String?
    var branch: String?
    var clean: Bool?
    var branchAhead: Int?
    var branchBehind: Int?
    var comparisonPrimaryCommit: String?
    var ahead: Int?
    var behind: Int?
}

struct DeviceStatusRules: Codable, Sendable {
    var state: String
    var runtime: DeviceStatusField<DeviceStatusFile>
    var bundledHash: String?
    // W68 records runtime/bundle hashes, NOT generation provenance. Never invent it.
    var generatedFromConstitutionHash: String?
}

struct DeviceStatusSnapshot: Codable, Sendable {
    var schema = "tatwo.device-status.v1"
    var identity: DeviceStatusField<DeviceIdentity>
    var appVersion: DeviceStatusField<String>
    var code: DeviceStatusField<DeviceStatusCode>
    var constitution: DeviceStatusField<DeviceStatusFile>
    var skillet: DeviceStatusField<DeviceStatusFile>
    var rules: DeviceStatusField<DeviceStatusRules>
    var gbrain: DeviceStatusField<String>

    static func decode(_ object: [String: Any]) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        guard value.schema == "tatwo.device-status.v1" else {
            throw CocoaError(.coderReadCorrupt)
        }
        if let identity = value.identity.value { _ = try identity.validated() }
        return value
    }

    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
    }
}

enum DeviceStatusReader {
    /// Installed by RuleGenerator.registerRuntime in production: what launch would write
    /// for this runtime path. Nil (fixtures) falls back to the bundled file hash.
    static var expectedRulesContent: ((String, URL?) throws -> Data)?
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func file(_ url: URL, now: Date = Date()) -> DeviceStatusField<DeviceStatusFile> {
        // resolvingSymlinksInPath may leave a dangling symlink unresolved on macOS.
        if !FileManager.default.fileExists(atPath: url.path) {
            let broken = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
            return .init(value: nil, acquiredAt: now, reason: broken ? "broken_link" : "missing")
        }
        do {
            // Bound text/RPC payloads; do not silently report a partial hash as whole-file truth.
            let attrs = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            guard (attrs[.type] as? FileAttributeType) == .typeRegular,
                  ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 262_144 else {
                return .init(value: nil, acquiredAt: now, reason: "not_regular_or_too_large")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 262_144 else {
                return .init(value: nil, acquiredAt: now, reason: "too_large")
            }
            return .init(value: .init(sha256: digest(data), text: String(data: data, encoding: .utf8)),
                         acquiredAt: now, reason: nil)
        } catch {
            let reason: String
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                reason = "broken_link"
            } else if !FileManager.default.fileExists(atPath: url.path) {
                reason = "missing"
            } else {
                reason = "unreadable"
            }
            return .init(value: nil, acquiredAt: now, reason: reason)
        }
    }

    /// Only fixed read-only git verbs. Disable index refresh/optional locks and fsmonitor hooks.
    static func git(_ repo: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", repo.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain before waiting (git status may be larger than a pipe buffer).
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    static func validCommit(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    static func distance(repo: URL, from: String, to: String) -> (Int, Int)? {
        guard validCommit(from), validCommit(to),
              let raw = git(repo, ["rev-list", "--left-right", "--count", "\(from)...\(to)", "--"])
        else { return nil }
        let parts = raw.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func read(
        entry: TatwoEntry = TatwoEntry(),
        runtimeURL: URL = URL(fileURLWithPath: OSUpstream.overridePath),
        bundledURL: URL? = OSUpstreamRefresh.bundledURL,
        appInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
        primaryCommit: String? = nil
    ) -> DeviceStatusSnapshot {
        let identity: DeviceStatusField<DeviceIdentity>
        do {
            let value = try DeviceIdentityStore.readLocal(entry: entry)
            identity = .init(value: value, acquiredAt: Date(), reason: value == nil ? "missing" : nil)
        } catch { identity = .init(value: nil, acquiredAt: Date(), reason: "invalid_identity") }
        let version = (appInfo["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let build = appInfo["CFBundleVersion"] as? String
        let app = version.map { $0 + (build.map { " (\($0))" } ?? "") }
        var code: DeviceStatusCode?
        if let commit = git(entry.repoRoot, ["rev-parse", "--verify", "refs/heads/beta1/integration^{commit}"]),
           validCommit(commit) {
            let head = git(entry.repoRoot, ["rev-parse", "--verify", "HEAD^{commit}"])
            let work = head.flatMap { distance(repo: entry.repoRoot, from: $0, to: commit) }
            let comparison = primaryCommit.flatMap { distance(repo: entry.repoRoot, from: commit, to: $0) }
            let status = git(entry.repoRoot, ["status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none"])
            code = .init(integrationCommit: commit, head: head,
                         branch: git(entry.repoRoot, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
                         clean: status.map(\.isEmpty), branchAhead: work?.0, branchBehind: work?.1,
                         comparisonPrimaryCommit: primaryCommit, ahead: comparison?.0, behind: comparison?.1)
        }
        let codeReason: String?
        if code == nil { codeReason = "integration_unavailable" }
        else if code?.clean == nil { codeReason = "worktree_status_unavailable" }
        else if code?.branchAhead == nil || code?.branchBehind == nil { codeReason = "work_branch_distance_unavailable" }
        else if primaryCommit != nil && code?.behind == nil { codeReason = "comparison_objects_unavailable" }
        else { codeReason = nil }
        let codeField = DeviceStatusField(value: code, acquiredAt: Date(), reason: codeReason)
        let constitution = file(entry.constitution)
        let skillet = file(entry.skillet)
        let runtime = file(runtimeURL)
        let bundled = bundledURL.map { file($0) }
        let currentHash = runtime.value?.sha256
        // W79: launch installs the constitution-generated upstream, so "aligned" compares
        // against what launch would write now, not the static bundled file. The generator
        // keeps the prior stamp time for an unchanged source, so equal content hashes equal.
        let bundledHash = (try? expectedRulesContent?(runtimeURL.path, bundledURL))
            .flatMap { $0 }.map(digest) ?? bundled?.value?.sha256
        let choice = try? String(contentsOf: runtimeURL.deletingLastPathComponent()
            .appendingPathComponent("os-upstream.kept-custom.sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let state: String
        if let currentHash, let bundledHash {
            state = currentHash == bundledHash ? "aligned"
                : choice == currentHash + "\n" + bundledHash ? "user_kept" : "pending"
        } else { state = "unknown" }
        // Provenance only from the generator stamp actually present in the runtime file.
        let stamp = "<!-- 由 OS 產生，來源憲法 sha256="
        var provenance: String?
        if let text = runtime.value?.text, text.hasPrefix(stamp) {
            let hex = text.dropFirst(stamp.count).prefix(64)
            if hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) { provenance = String(hex) }
        }
        let rules = DeviceStatusRules(state: state, runtime: runtime, bundledHash: bundledHash,
                                      generatedFromConstitutionHash: provenance)
        return .init(identity: identity,
                     appVersion: .init(value: app, acquiredAt: Date(), reason: app == nil ? "info_plist_missing" : nil),
                     code: codeField, constitution: constitution, skillet: skillet,
                     rules: .init(value: rules, acquiredAt: Date(),
                                  reason: runtime.reason ?? (bundledHash == nil ? "bundled_missing"
                                                              : provenance == nil ? "provenance_unavailable" : nil)),
                     gbrain: GBrainHealth.read(entry: entry))
    }

    static func registry(environment: [String: String] = ProcessInfo.processInfo.environment) -> [DeviceRecord] {
        let root = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/live")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: root.appendingPathComponent("devices.json")) else { return [] }
        return (try? decoder.decode([DeviceRecord].self, from: data)) ?? []
    }
}

/// Read-only projection of the service's actual MCP probe, not MCP registration.
/// Kept here so standalone device_status probes don't launch App services or touch Keychain.
enum GBrainHealth {
    static func read(entry: TatwoEntry, now: Date = Date()) -> DeviceStatusField<String> {
        guard let data = try? Data(contentsOf: entry.gbrainDir.appendingPathComponent("state.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .init(value: nil, acquiredAt: now, reason: "not_configured") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let stamp = object["acquiredAt"] as? String,
              let date = formatter.date(from: stamp),
              date <= now.addingTimeInterval(5), now.timeIntervalSince(date) <= 60
        else { return .init(value: nil, acquiredAt: .distantPast, reason: "stale") }
        let mode = object["mode"] as? String ?? "unknown"
        let names = ["pglite": "主設備本機 PGLite", "legacy": "主設備 Postgres（相容模式）",
                     "ssh-stdio": "連主設備（SSH）", "ssh-http": "連主設備（HTTP＋SSH）"]
        let label = names[mode] ?? "未設定"
        let healthy = object["healthy"] as? Bool == true
        return .init(value: label, acquiredAt: date,
                     reason: healthy ? nil : (object["reason"] as? String ?? "health_unavailable"))
    }
}

enum DeviceStatusConnection: String, Codable, Sendable {
    case local, reachable, sshUnavailable, appUnavailable
    var online: Bool { self == .local || self == .reachable }
}

struct DeviceStatusProbe: Sendable {
    var connection: DeviceStatusConnection
    var snapshot: DeviceStatusSnapshot?
    var acquiredAt: Date
    var reason: String?
}

enum DeviceStatusLight: String, CaseIterable, Sendable { case green, yellow, red, gray }
enum DeviceStatusColumn: String, CaseIterable, Sendable {
    case identity, connection, app, code, constitution, rules, gbrain
}

/// Policy is deliberately independent from presentation. Unknown is never equality.
enum DeviceStatusPolicy {
    static let ttl: TimeInterval = 60
    static func fresh(_ acquiredAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(acquiredAt)
        return age >= -5 && age <= ttl
    }

    static func light(
        column: DeviceStatusColumn, known: Bool, online: Bool, acquiredAt: Date,
        now: Date = Date(), matches: Bool? = nil, reason: String? = nil,
        userKept: Bool = false
    ) -> DeviceStatusLight {
        guard online else { return column == .connection ? .red : .gray }
        guard fresh(acquiredAt, now: now) else { return .gray }
        if ["missing", "broken_link", "invalid_identity", "unreadable", "unhealthy"].contains(reason ?? "") {
            return .red
        }
        guard known else { return .gray }
        if column == .rules && userKept { return .yellow }
        guard let matches else { return .yellow }
        if matches { return reason == nil ? .green : .yellow }
        return [.identity, .constitution, .gbrain].contains(column) ? .red : .yellow
    }

    /// Exactly one current primary and an explicit local primaryDeviceID are required.
    /// Registry UUIDs are intentionally absent from this API.
    static func primary(local: DeviceStatusSnapshot?, probes: [DeviceStatusProbe], now: Date) -> DeviceStatusSnapshot? {
        guard let local, fresh(local.identity.acquiredAt, now: now),
              let localID = local.identity.value,
              let primaryID = localID.primaryDeviceID, let epoch = localID.epoch else { return nil }
        let primaries = probes.filter {
            $0.connection.online && fresh($0.acquiredAt, now: now)
                && $0.snapshot?.identity.value?.role == .primary
        }.compactMap(\.snapshot)
        guard primaries.count == 1, let primary = primaries.first,
              fresh(primary.identity.acquiredAt, now: now),
              let identity = primary.identity.value, identity.epoch == epoch,
              identity.deviceID.lowercased() == primaryID.lowercased() else { return nil }
        return primary
    }
}

enum DeviceStatusDiff {
    /// Bounded line diff without subprocesses, temporary files, or writes.
    static func text(local: String?, primary: String?) -> String {
        guard let local, let primary else { return "無法比較：本機或主設備文字缺失。" }
        if local == primary { return "內容相同" }
        let a = primary.components(separatedBy: "\n"), b = local.components(separatedBy: "\n")
        // CollectionDifference uses bounded input here; huge texts display lossless two-sided text.
        guard a.count + b.count <= 4_000 else {
            return "--- 主設備\n" + primary + "\n+++ 本機\n" + local
        }
        let changes = b.difference(from: a)
        var lines = ["--- 主設備", "+++ 本機"]
        for change in changes {
            switch change {
            case .remove(let offset, let element, _): lines.append("- \(offset + 1): \(element)")
            case .insert(let offset, let element, _): lines.append("+ \(offset + 1): \(element)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
