import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const facade = path.join(root, 'App/Sources/Tatwo2/Facade');
const main = String.raw`
import Foundation
struct ClaudeSidecar {
    static func engineHomeRoot() -> URL { URL(fileURLWithPath: "/unused-fixture-home") }
}
@MainActor
final class Probe {
    var reviews = 0
    var reviewedText = ""
    var calls: [URLRequest] = []
    var output = #"{"decision":"allow","reason":"none"}"#
    var status = 201
    var networkError = false
    var reconcileBody = "[]"
    var identity = "fixture-user"
    func review(_ text: String) async throws -> String { reviews += 1; reviewedText = text; return output }
    func http(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        let code: Int; let body: String
        if request.url!.path == "/user" { code = 200; body = "{\"login\":\"\(identity)\"}" }
        else if request.httpMethod == "GET" { code = 200; body = reconcileBody }
        else {
            if networkError { throw URLError(.timedOut) }
            code = status; body = status == 201 ? "{\"number\":71}" : "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}
@MainActor
func check(_ condition: @autoclosure () -> Bool, _ note: String) { if !condition() { fatalError(note) } }
@MainActor
func fails(_ expected: FeedbackFailure, _ body: () async throws -> Void) async {
    do { try await body(); fatalError("expected rejection: \(expected)") }
    catch let error as FeedbackFailure { check(error == expected, "unexpected rejection: \(error), expected \(expected)") }
    catch { fatalError("unexpected error: \(error)") }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let identity = FeedbackIdentity(username: "fixture-user", token: "synthetic-credential-not-real")
        func fixture() throws -> (FeedbackService, Probe, URL) {
            let probe = Probe(), url = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("draft.json")
            let service = try FeedbackService(draftURL: url, reviewer: probe.review, http: probe.http, repository: { "fixture-owner/feedback" })
            try service.update(title: "A critical bug", body: "This feature is broken. Repro: print(1).", account: identity.username)
            return (service, probe, url)
        }
        check(TatwoSlashCommandParser.feedbackArgument(in: "/feedback") == "", "empty command")
        check(TatwoSlashCommandParser.feedbackArgument(in: "/feedback detail") == "detail", "command payload")
        check(TatwoSlashCommandParser.feedbackArgument(in: "/feedbacking") == nil, "command prefix")
        check(TatwoSlashCommandParser.feedbackArgument(in: "a note\n/feedback") == nil, "note should not become upload")
        let args = try FeedbackNativeReview.codexArguments(root: root, features: "shell_tool stable true\nhooks stable true\nplugins stable true\napps stable true\nunified_exec stable true")
        let catalogArgument = args.first { $0.hasPrefix("model_catalog_json=") }!
        check(!catalogArgument.contains("\\/"), "JSON slash escape is invalid TOML for native config path")
        check(catalogArgument.hasPrefix("model_catalog_json=\"/"), "native catalog path not a quoted absolute path")
        check(args.contains("--ignore-user-config") && args.contains("--ignore-rules") && args.contains("--ephemeral"), "native isolation absent")
        check(args.contains("features.shell_tool=false") && args.contains("features.hooks=false") && args.contains("features.plugins=false"), "native feature isolation absent")
        check(args.contains("tools.update_plan.enabled=false") && args.contains("mcp_servers={}"), "native tool isolation absent")
        check(args[args.firstIndex(of: "--model")! + 1] == "gpt-5.4-mini", "model not pinned")
        let catalog = try FeedbackNativeReview.codexCatalog(Data(#"{"models":[{"slug":"gpt-5.4-mini","shell_type":"unified_exec","apply_patch_tool_type":"freeform","model_messages":{"private":"must not inherit"}}]}"#.utf8))
        let catalogObject = try JSONSerialization.jsonObject(with: catalog) as! [String: Any]
        let selected = (catalogObject["models"] as! [[String: Any]])[0]
        check(selected["shell_type"] as? String == "disabled" && selected["apply_patch_tool_type"] is NSNull, "native executable tools remained")
        check(selected["model_messages"] == nil && selected["base_instructions"] as? String == FeedbackNativeReview.policy, "native inherited model instructions")
        let answer = #"{"decision":"allow","reason":"none"}"#
        let event = try JSONSerialization.data(withJSONObject: ["type":"item.completed","item":["type":"agent_message","text":answer]])
        let stream = event + Data("\n{\"type\":\"turn.completed\"}\n".utf8)
        let parsed = try FeedbackNativeReview.parseCodexOutput(stream)
        check(parsed == answer, "native result parser")
        await fails(.reviewUnavailable) {
            _ = try FeedbackNativeReview.parseCodexOutput(Data(#"{"type":"item.completed","item":{"type":"command_execution"}}"#.utf8) + Data("\n".utf8) + stream)
        }
        await fails(.reviewUnavailable) { _ = try FeedbackNativeReview.parseCodexOutput(event) }
        do {
            let (service, probe, _) = try fixture()
            await fails(.changed) { _ = try await service.submit(identity: identity) }
            check(probe.calls.isEmpty, "unreviewed POST")
            try service.update(title: "token", body: "ghp_" + String(repeating: "a", count: 36), account: identity.username)
            await fails(.credential) { try await service.review(identity: identity) }
            check(probe.reviews == 0 && probe.calls.isEmpty, "secret transmitted before local preflight")
        }
        for output in ["bad JSON", "{}", #"{"decision":"allow","reason":"privacy"}"#, #"{"decision":"allow","reason":"none","extra":"x"}"#] {
            let (service, probe, _) = try fixture(); probe.output = output
            await fails(.reviewUnavailable) { try await service.review(identity: identity) }
            await fails(.changed) { _ = try await service.submit(identity: identity) }
            check(probe.calls.isEmpty, "malformed review allowed HTTP")
        }
        do {
            let (service, probe, _) = try fixture()
            probe.output = #"{"decision":"block","reason":"privacy"}"#
            await fails(.reviewRejected("含有明確私人敏感資訊，請移除後重審")) { try await service.review(identity: identity) }
            await fails(.changed) { _ = try await service.submit(identity: identity) }
            check(probe.calls.isEmpty, "blocked review POST")
        }
        do {
            let (service, probe, _) = try fixture()
            try await service.review(identity: identity)
            await fails(.changed) { _ = try await service.submit(identity: FeedbackIdentity(username: identity.username, token: "changed-token")) }
            try service.update(title: "edited", body: service.draft.body, account: identity.username)
            await fails(.changed) { _ = try await service.submit(identity: identity) }
            check(probe.calls.isEmpty, "edited payload retained approval")
        }
        do {
            let (service, probe, url) = try fixture()
            try await service.review(identity: identity)
            let reopened = try FeedbackService(draftURL: url, reviewer: probe.review, http: probe.http, repository: { "fixture-owner/feedback" })
            await fails(.changed) { _ = try await reopened.submit(identity: identity) }
            let before = service.draft
            let number = try await service.submit(identity: identity)
            check(number == 71 && probe.reviews == 1, "successful issue")
            check(probe.calls.count == 2 && probe.calls[0].url!.path == "/user", "identity validation missing")
            let post = probe.calls.last!
            let payload = try JSONSerialization.jsonObject(with: post.httpBody!) as! [String: String]
            // W4 intentionally reviews and submits the original body plus an environment footer.
            let expectedBody = FeedbackEnvironment.current().appending(to: before.body)
            check(expectedBody.hasPrefix(before.body + "\n\n---\n"), "environment footer changed original text")
            check(service.draft.title == before.title && service.draft.body == before.body, "raw draft modified")
            check(payload == ["title": before.title, "body": expectedBody], "unexpected augmented payload")
            let reviewed = try JSONSerialization.jsonObject(with: Data(probe.reviewedText.utf8)) as! [String: String]
            check(reviewed == payload && service.draft.deliveryBody == expectedBody, "review/delivery bytes differ")
            check(post.url!.absoluteString == "https://api.github.com/repos/fixture-owner/feedback/issues", "wrong repo")
            await fails(.uncertain) { _ = try await service.submit(identity: identity) }
            check(probe.calls.count == 2, "successful issue retried")
            try service.beginNewDraft()
            check(service.draft.title.isEmpty && service.draft.issueNumber == nil, "cannot create next report")
        }
        do {
            let (service, probe, _) = try fixture(); probe.identity = "someone-else"
            try await service.review(identity: identity)
            await fails(.login) { _ = try await service.submit(identity: identity) }
            check(probe.calls.count == 1 && probe.calls[0].httpMethod == "GET", "account mismatch POST")
        }
        for status in [403, 404] {
            let (service, probe, _) = try fixture(); probe.status = status
            try await service.review(identity: identity)
            await fails(.permission) { _ = try await service.submit(identity: identity) }
            check(!service.draft.deliveryPending && probe.calls.count == 2, "permission error blind retry")
            await fails(.changed) { _ = try await service.submit(identity: identity) }
        }
        for status in [500, 302, 201] {
            let (service, probe, url) = try fixture(); probe.status = status; probe.networkError = status == 201
            try await service.review(identity: identity)
            await fails(.uncertain) { _ = try await service.submit(identity: identity) }
            check(service.draft.deliveryPending, "unknown response unlocked retry")
            let reopened = try FeedbackService(draftURL: url, reviewer: probe.review, http: probe.http, repository: { "fixture-owner/feedback" })
            await fails(.uncertain) { _ = try await reopened.submit(identity: identity) }
            check(probe.calls.count == 2, "restart caused duplicate POST")
            let result = try await reopened.reconcile(identity: identity)
            check(result == nil && reopened.draft.deliveryPending, "empty lookup unlocked retry")
        }
        do {
            let (service, probe, _) = try fixture(); probe.networkError = true
            try await service.review(identity: identity)
            await fails(.uncertain) { _ = try await service.submit(identity: identity) }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let row: [String: Any] = ["number": 88, "title": service.draft.title, "body": service.draft.deliveryBody!,
                                      "created_at": stamp, "user": ["login": identity.username]]
            probe.reconcileBody = String(decoding: try JSONSerialization.data(withJSONObject: [row]), as: UTF8.self)
            let found = try await service.reconcile(identity: identity)
            check(found == 88 && !service.draft.deliveryPending, "confirmed lookup not reconciled")
        }
        // Native model failure is not fabricated approval.
        do {
            let probe = Probe(), url = root.appendingPathComponent("unavailable/draft.json")
            let service = try FeedbackService(draftURL: url, reviewer: { _ in throw URLError(.timedOut) }, http: probe.http, repository: { "fixture-owner/feedback" })
            try service.update(title: "normal", body: "normal bug", account: identity.username)
            await fails(.reviewUnavailable) { try await service.review(identity: identity) }
            await fails(.changed) { _ = try await service.submit(identity: identity) }
            check(probe.calls.isEmpty, "model unavailable fabricated approval")
        }
        print("PASS feedback production service: preflight, bound review, identity, exact payload, durable uncertainty; mock HTTP/model only")
    }
}
`;

test('feedback service enforces review and preserves uncertain drafts (no real model or POST)', {
  skip: process.platform !== 'darwin', timeout: 180_000,
}, () => {
  const artifacts = path.join(root, 'output/lightweight-repair'); fs.mkdirSync(artifacts, { recursive: true });
  const dir = fs.mkdtempSync(path.join(artifacts, 'feedback-'));
  const source = path.join(dir, 'FeedbackTests.swift'); fs.writeFileSync(source, main);
  const run = (cmd, args) => spawnSync(cmd, args, { cwd: root, encoding: 'utf8', timeout: 120_000,
    env: { ...process.env, TMPDIR: `${dir}/` }, maxBuffer: 8 * 1024 * 1024 });
  const lock = path.join(root, 'scripts/tatwo-build-lock.sh');
  const acquired = run('bash', [lock, 'acquire', '--timeout', '60', '--pid', String(process.pid)]);
  assert.equal(acquired.status, 0, `build lock unavailable: ${acquired.stderr}`);
  const token = acquired.stdout.match(/^token=([a-f0-9]+)$/m)?.[1]; assert.ok(token);
  try {
    const build = run('/usr/bin/nice', ['-n', '10', '/usr/bin/swiftc', '-num-threads', '2',
      path.join(facade, 'FeedbackService.swift'), path.join(facade, 'FeedbackNativeReview.swift'),
      path.join(root, 'App/Sources/Tatwo2/Chat/SlashCommandParser.swift'), source, '-o', path.join(dir, 'fixture')]);
    fs.writeFileSync(path.join(dir, 'compile.log'), `${build.stdout ?? ''}${build.stderr ?? ''}`);
    assert.equal(build.status, 0, `compile failed: ${build.stderr}`);
    const result = run(path.join(dir, 'fixture'), [path.join(dir, 'data')]);
    fs.writeFileSync(path.join(dir, 'result.log'), `${result.stdout ?? ''}${result.stderr ?? ''}`);
    assert.equal(result.status, 0, `fixture failed: ${result.stderr}`);
    assert.match(result.stdout, /PASS feedback production service/);
  } finally {
    const release = run('bash', [lock, 'release', '--token', token, '--pid', String(process.pid)]);
    assert.equal(release.status, 0, release.stderr);
  }
});
