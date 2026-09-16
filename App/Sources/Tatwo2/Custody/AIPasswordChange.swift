import Combine
import Foundation
import Security

@MainActor
final class AIPasswordChange: ObservableObject {
    enum Stage: String, CaseIterable {
        case idle, generating, opening, asking, loggingIn, filling, confirming
        case authenticating, staging, submitting, verifying, committing, complete, failed
    }
    @Published private(set) var stage: Stage = .idle
    private(set) var failedAt: Stage?
    enum Failure: Error { case denied, stale, unsupported, unconfirmed }

    struct Operations {
        let current: () -> Bool
        let generate: () throws -> String
        let open: (URL) async throws -> Void
        let ask: () async -> Bool
        let login: () async throws -> Void
        let fill: (String) async throws -> Void
        let confirm: () async -> Bool
        let authenticate: () async throws -> Void
        let stageSecret: (String) throws -> Void
        let submit: () throws -> Void
        let verify: () async throws -> Bool
        let commit: (String) throws -> Void
        let cancel: () -> Void
        let failed: () -> Void
    }

    /// No fallback commit and no automatic replay. The old vault secret changes ONLY at commit.
    func run(origin: String, automaticallyAssisted: Bool = false, operations op: Operations) async {
        guard stage == .idle, let url = Self.destination(origin: origin) else { return }
        var proposed = ""
        defer { proposed = ""; op.cancel() }
        func check() throws {
            guard op.current(), !Task.isCancelled else { throw Failure.stale }
        }
        do {
            stage = .generating; try check(); proposed = try op.generate()
            stage = .opening; try check(); try await op.open(url); try check()
            stage = .asking
            // The saved opt-in replaces only the FIRST prompt, never final confirmation/authentication.
            if !automaticallyAssisted { guard await op.ask() else { throw Failure.denied } }
            try check()
            stage = .loggingIn; try await op.login(); try check()
            stage = .confirming; guard await op.confirm() else { throw Failure.denied }; try check()
            stage = .authenticating; try await op.authenticate(); try check()
            // Recovery candidate survives an indeterminate network result or failed Keychain commit.
            stage = .staging; try op.stageSecret(proposed); try check()
            // Page setters/listeners may submit on input. Do not disclose either password before auth.
            stage = .filling; try await op.fill(proposed); try check()
            stage = .submitting; try op.submit()
            stage = .verifying; guard try await op.verify() else { throw Failure.unconfirmed }; try check()
            stage = .committing; try op.commit(proposed)
            stage = .complete
        } catch {
            failedAt = stage; stage = .failed
            op.failed()
        }
    }

    nonisolated static func destination(origin: String) -> URL? {
        guard let normalized = BrowserPasswordOrigin.normalized(origin),
              normalized.hasPrefix("https://"), let url = URL(string: normalized) else { return nil }
        let path: String
        switch url.host {
        case "github.com": path = "/settings/security"
        case "x.com": path = "/settings/password"
        default: path = "/"
        }
        return URL(string: normalized + path)
    }

    nonisolated static func strongPassword() throws -> String {
        func random(_ upper: Int) throws -> Int {
            var byte: UInt8 = 0
            repeat {
                guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw Failure.unsupported }
            } while Int(byte) >= 256 - (256 % upper)
            return Int(byte) % upper
        }
        let groups = [Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), Array("abcdefghijklmnopqrstuvwxyz"),
                      Array("0123456789"), Array("!@#$%^&*-_=+?")]
        let all = groups.flatMap { $0 }
        var password = try groups.map { $0[try random($0.count)] }
        while password.count < 20 { password.append(all[try random(all.count)]) }
        for i in stride(from: password.count - 1, through: 1, by: -1) { password.swapAt(i, try random(i + 1)) }
        return String(password)
    }
}
