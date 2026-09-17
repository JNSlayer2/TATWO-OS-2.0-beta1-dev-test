import Foundation
import CryptoKit

/// Local derivation only. Neither the constitution nor device.json is ever written here.
enum RuleGenerator {
    static let sections = ["0", "1", "2.1", "2.2", "2.3", "2.4", "4", "5", "8"]
    static let summaryHeading = "## 引擎摘要"
    private static let lock = NSLock()
    private static var dates: [String: String] = [:]

    struct Sources {
        let constitution: String
        let constitutionHash: String
        let identityHash: String
        let identity: DeviceIdentity
        let primaryName: String
        let boundaries: String
        let root: String
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Slice original bytes as text, including headings, lists and tables; never paraphrase clauses.
    static func section(_ number: String, in text: String) -> String? {
        let lines = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.range(of: "^#{2,3} " + NSRegularExpression.escapedPattern(for: number) + "(?:[.。 ]|$)",
                     options: .regularExpression) != nil
        }) else { return nil }
        let depth = lines[start].prefix(while: { $0 == "#" }).count
        let end = lines.indices.dropFirst(start + 1).first(where: {
            let count = lines[$0].prefix(while: { $0 == "#" }).count
            return count >= 2 && count <= depth && lines[$0].dropFirst(count).hasPrefix(" ")
        }) ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    static func sources(environment: [String: String]) throws -> Sources {
        let entry = TatwoEntry(environment: environment)
        // Bounded, read-only inputs. Hash the original bytes, not re-encoded JSON.
        let constitution = try OSUpstreamBinding.readText(entry.constitution.path)
        let json = try OSUpstreamBinding.readText(entry.deviceJSON.path)
        let identity = try DeviceIdentity.decode(Data(json.utf8))
        let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        var primary = fields["primaryDeviceName"] as? String
        if identity.role == .primary { primary = identity.name }
        if primary == nil, identity.primaryDeviceID != nil,
           let roles = section("2.1", in: constitution),
           let range = roles.range(of: #"主設備[＝=]([^*（(\s]+)"#, options: .regularExpression) {
            primary = String(roles[range]).components(separatedBy: CharacterSet(charactersIn: "＝=")).last
        }
        let boundaries = (fields["boundaries"] as? [String])?.joined(separator: "\n")
            ?? fields["boundaries"] as? String
            ?? "device.json 未另列邊界；適用下列憲法 §2 與 §8，不推定額外權限。"
        return Sources(constitution: constitution, constitutionHash: hash(Data(constitution.utf8)),
                       identityHash: hash(Data(json.utf8)), identity: identity,
                       primaryName: primary ?? "尚未確認（不得自行接管）", boundaries: boundaries,
                       root: entry.root.path)
    }

    static func generate(environment: [String: String], runtimePath: String, now: Date = Date()) throws -> String {
        let source = try sources(environment: environment)
        return try generate(source: source, runtimePath: runtimePath, now: now)
    }

    /// Onboarding renders the same translators before any entrance or engine file exists.
    static func generate(source: Sources, runtimePath: String, now: Date = Date()) throws -> String {
        let key = source.constitutionHash + ":" + source.identityHash
        let stampPrefix = "<!-- 由 OS 產生，來源憲法 sha256=\(source.constitutionHash)、身份 sha256=\(source.identityHash)、產生時間="
        // Retain the generation time for the same source version, including a kept proposal.
        let candidates = [runtimePath, (runtimePath as NSString).deletingLastPathComponent + "/os-upstream.kept-generated.md"]
        let prior = candidates.compactMap { try? OSUpstreamBinding.readText($0) }
            .compactMap { text -> String? in
                guard text.hasPrefix(stampPrefix),
                      let end = text.range(of: "；勿手改 -->") else { return nil }
                return String(text[text.index(text.startIndex, offsetBy: stampPrefix.count)..<end.lowerBound])
            }.first
        let date = lock.withLock { () -> String in
            if let prior { return prior }
            if let cached = dates[key] { return cached }
            let value = ISO8601DateFormatter().string(from: now)
            dates[key] = value
            return value
        }
        let clauses: String
        if let start = source.constitution.range(of: summaryHeading + "\n") {
            let rest = source.constitution[start.lowerBound...]
            let end = rest.dropFirst(summaryHeading.count + 1).range(of: "\n## ")?.lowerBound ?? rest.endIndex
            clauses = String(rest[..<end])
        } else {
            clauses = try sections.map { number in
                guard let text = section(number, in: source.constitution) else {
                    throw OSUpstreamBinding.failure("憲法缺少 §\(number)，停止產生")
                }
                return text
            }.joined(separator: "\n")
        }
        return """
        \(stampPrefix)\(date)；勿手改 -->
        # OS 執行期上游
        最上游憲法在 `~/AI/TATWO OS/os.md`（本機入口：`\(source.root)/os.md`）。

        ## 本機身份（device.json）
        名稱：\(source.identity.name)
        角色：\(source.identity.role.rawValue)（\(source.identity.role == .primary ? "主設備" : "副設備")）
        主設備：\(source.primaryName)
        主設備 ID：\(source.identity.primaryDeviceID ?? "未指派")
        邊界：\(source.boundaries)
        身份只描述本機，不授予憲法以外的權限；下列條文中其他設備的名稱不是本機名稱。

        \(clauses)
        """
    }

    /// Looking up a runtime path is not a launch: pre-launch W71 migration probes remain
    /// file-based. Activate binding generation on the first real source read, before services.
    static func registerRuntime(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var activated = false
        DeviceStatusReader.expectedRulesContent = { runtime, bundled in
            try OSUpstreamRefresh.expectedContent(runtimePath: runtime, bundled: bundled)
        }
        OSUpstreamRefresh.generatedContent = { runtime, now in
            lock.withLock {
                if !activated {
                    configureBindings()
                    activated = true
                }
            }
            return Data(try generate(environment: environment, runtimePath: runtime, now: now).utf8)
        }
    }

    /// Tests install the same production providers with explicit synthetic inputs.
    static func configure(environment: [String: String] = ProcessInfo.processInfo.environment) {
        registerRuntime(environment: environment)
        configureBindings()
    }

    private static func configureBindings() {
        OSUpstreamBinding.externalTargets = { home in
            RuleTranslators.all.compactMap { translator in
                translator.externalFile.map {
                    UpstreamBindingTarget(id: translator.engine + "-cli",
                                          label: "\(translator.engine) CLI（~/\($0)）", path: home + "/" + $0)
                }
            }
        }
        OSUpstreamBinding.runtimeSource = { env in
            try OSUpstreamBinding.readText(OSUpstream.runtimePath(environment: env))
        }
        OSUpstreamBinding.translatedBlock = { target, env, hash in
            let source = try sources(environment: env)
            return try RuleTranslators.translator(for: target.id).managedBlock(
                source: source, runtimePath: OSUpstream.runtimePath(environment: env), hash: hash)
        }
    }
}
