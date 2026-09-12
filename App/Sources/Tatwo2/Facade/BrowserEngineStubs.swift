// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/BrowserNetworkSecurity.swift:179-217、353-365；Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WebMCPBridge.swift:121-181；只保留 Chromium 畫面用到的欄位。
import Foundation
@_exported import TatwoCEFBridge

// 治理實作不搬；保留 CEF request-context 隔離判斷所需的值型別。
enum BrowserProfilePolicyTag: String, Codable, Equatable, Sendable {
    case humanPersistent = "human-persistent"
    case humanEphemeral = "human-ephemeral"
    case agentEphemeral = "agent-ephemeral"

    static func mayShareRequestContext(
        _ lhs: BrowserProfilePolicyTag,
        _ rhs: BrowserProfilePolicyTag
    ) -> Bool { lhs == rhs }
}

// 真實 deny-list 由打包腳本複製；Facade 只解析 app bundle 內的同名資源。
enum BrowserBundledHostDenyList {
    enum VerificationError: Error { case resourceMissing }

    static func verifiedResourceURL() throws -> URL {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("BrowserBlocklists", isDirectory: true)
            .appendingPathComponent("browser-host-deny-list.json")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw VerificationError.resourceMissing
        }
        return url
    }
}

// WebMCP 本輪明定不接；保留 backend 原畫面呼叫的同名 no-op 水電。
final class TatwoWebMCPRuntime: @unchecked Sendable {
    typealias MainActorInvoker = @MainActor (
        _ pageToolName: String,
        _ argumentsJSON: String,
        _ navigationGeneration: UInt64,
        _ completion: @escaping (String?, String?) -> Void
    ) -> Void

    static let shared = TatwoWebMCPRuntime()
    private init() {}

    func update(tabID: String, snapshotJSONString: String) {}
    func activate(tabID: String) {}
    func attach(tabID: String, invoker: @escaping MainActorInvoker) {}
    func detach(tabID: String) {}
}
