import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

// Compile the actual watchdog with an in-memory engine and deterministic stats.
// No timer is run and no account, model, or production session is opened.
const repo = process.cwd();
const file = 'App/Sources/Tatwo2/Facade/DispatchWatchdog.swift';
const source = fs.readFileSync(file, 'utf8');
const start = source.indexOf('    static func machineStats() -> MachineStats {');
assert.ok(start > 0);
const root = fs.mkdtempSync(path.join(repo, 'output/lightweight-repair/watchdog-pressure.'));
const program = path.join(root, 'probe');
fs.writeFileSync(path.join(root, 'probe.swift'), `
import Foundation
enum ThreadLiveness {
    case stalled, idle, active, done, failed
    static func from(status: String?, lastOutputAt: Date?) -> Self? { .active }
}
struct Thread {
    var id = UUID()
    var title = "fixture"
    var parentThreadID: UUID?
    var subStatus: String?
    var lastOutputAt: Date?
}
@MainActor final class ChatLiveEngine {
    struct Doc { var threads: [Thread] = []; var selectedThreadID: UUID? }
    var doc = Doc()
    var dispatchPaused = false
    var onChange: (() -> Void)?
    var messages: [(UUID, String)] = []
    func stop(threadID: UUID) {}
    func markSubStatus(_ id: UUID, _ status: String) {}
    func appendSystemMessage(threadID: UUID, text: String) { messages.append((threadID, text)) }
}
${source.slice(0, start)}
    static var fixtureStats = MachineStats(usedMemoryPercent: 30, load1: 0)
    static func machineStats() -> MachineStats { fixtureStats }
}
@MainActor func probe() {
    let mode = CommandLine.arguments[1]
    let engine = ChatLiveEngine()
    let parent = Thread()
    let history = Thread()
    let unrelated = Thread()
    engine.doc.threads = [parent, history, unrelated,
        Thread(parentThreadID: parent.id, subStatus: "running"),
        Thread(parentThreadID: history.id, subStatus: "done")]
    engine.doc.selectedThreadID = unrelated.id
    let watchdog = DispatchWatchdog.attach(to: engine)
    watchdog.stop()
    func tick(_ memory: Int, _ load: Double = 0) {
        DispatchWatchdog.fixtureStats = .init(usedMemoryPercent: memory, load1: load)
        watchdog.tick()
    }
    func check(_ value: Bool) { print(value ? "PASS" : "FAIL") }
    switch mode {
    case "target":
        tick(90)
        check(engine.messages.count == 1 && engine.messages.first?.0 == parent.id)
    case "idle":
        engine.doc.threads.removeAll { $0.parentThreadID != nil }
        tick(90)
        check(engine.dispatchPaused && engine.messages.isEmpty)
    case "memory":
        tick(90); tick(84); tick(86); tick(82)
        check(engine.dispatchPaused && engine.messages.count == 1)
        tick(79)
        check(!engine.dispatchPaused && engine.messages.count == 2)
    case "cpu":
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        tick(30, cores * 1.6); tick(30, cores * 1.4)
        check(engine.dispatchPaused && engine.messages.count == 1)
        tick(30, cores)
        check(!engine.dispatchPaused && engine.messages.count == 2)
    case "finished":
        tick(90)
        engine.doc.threads[3].subStatus = "done"
        tick(30)
        check(!engine.dispatchPaused && engine.messages.count == 1)
    case "new":
        tick(90)
        engine.doc.threads[3].subStatus = "done"
        engine.doc.threads.append(Thread(parentThreadID: unrelated.id, subStatus: "running"))
        tick(90); tick(90); tick(30)
        check(engine.messages.count == 3 && engine.messages[1].0 == unrelated.id &&
              engine.messages[2].0 == unrelated.id)
    case "orphan":
        engine.doc.threads = [Thread(parentThreadID: UUID(), subStatus: "running")]
        tick(90)
        check(engine.dispatchPaused && engine.messages.isEmpty)
    default: fatalError("unknown probe")
    }
}
MainActor.assumeIsolated { probe() }
`);
execFileSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 120 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
xcrun swiftc "$1" -o "$2"
`, 'watchdog-pressure', path.join(root, 'probe.swift'), program],
{ cwd: repo, timeout: 150000, env: { ...process.env, TMPDIR: root }, stdio: 'pipe' });

for (const [mode, description] of [
  ['target', 'only running children notify their existing parent'],
  ['idle', 'no unsolicited pressure messages in selected idle chat'],
  ['memory', 'memory hysteresis prevents alternating pressure chatter'],
  ['cpu', 'load hysteresis waits for actual recovery'],
  ['finished', 'completed work does not receive recovery chatter'],
  ['new', 'new active parent receives one alert and its own recovery'],
  ['orphan', 'deleted parent is not recreated for pressure notification'],
]) {
  test(description, () => {
    const output = execFileSync(program, [mode], { encoding: 'utf8' }).trim().split('\n');
    assert.ok(output.length && output.every(line => line === 'PASS'), output.join('\n'));
  });
}
