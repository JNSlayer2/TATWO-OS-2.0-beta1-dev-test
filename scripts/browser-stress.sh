#!/bin/bash
# W60: read-only MacBook runtime receipts; never launches, installs or kills an App.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:---plan}" == --plan ]]; then
cat <<'PLAN'
Use an authorized disposable CEF candidate/profile, never the working App's profile.
Record candidate revision/hash, run ID, timestamp, surface and viewport beside your video.
1. Capture baseline. Open 30 example.com tabs via the visible New Tab button.
2. Select tabs 200 times (index = (iteration * 17 + 3) % 30); record no white/gray flashes.
3. Capture loaded. Close the first 20; capture closed (10 records remain).
4. Leave both browser surfaces; wait idle threshold + 35 seconds; capture sleeping.
5. Wake one tab, capture awake; close the remaining tabs, capture done.
Repeat in chat and work space; attempt a second same-session panel/window.
Verify the first surface is not stolen; no automatic crash retry or profile reset is allowed.

Capture each stage:
  bash scripts/browser-stress.sh --capture PID HELPER_ROOT REGISTRY_JSON baseline|loaded|closed|sleeping|awake|done
Stdout is numeric JSON only. Redirect it to your PRIVATE local evidence directory.
No stage asserts PASS: match video, registry counts, native close-completion telemetry,
diagnostics restart/termination reasons, and helper footprint against the same candidate.
BrowserTabRegistry is not a count of live renderer processes (site isolation may share them).
activeLeaseCount must be checked in the native debugger/fixture; RSS alone cannot prove release.
Pure-layer tests:
  node --test tests/browser-stress.test.mjs
Pump runtime: launch the disposable candidate with TATWO_CEF_PUMP_PROBE=1, then:
  bash scripts/browser-pump-probe.sh --log TELEMETRY_FILE
Repeat an identical 5-second workload on an instrumented baseline; do not use fixture
stub-call numbers as real CEF performance.
PLAN
exit 0
fi
[[ "${1:-}" == --capture && $# == 5 && "$2" =~ ^[1-9][0-9]*$ ]] || {
  echo 'Usage: browser-stress.sh --plan | --capture PID HELPER_ROOT REGISTRY_JSON STAGE' >&2; exit 2;
}
case "$5" in baseline|loaded|closed|sleeping|awake|done) ;; *) exit 2 ;; esac
cd "$ROOT"
WORK="$ROOT/.build/w60/runtime-stress"
mkdir -p "$WORK"
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import Darwin
let pid = pid_t(CommandLine.arguments[1])!
guard kill(pid, 0) == 0 else { fatalError("candidate not alive/readable") }
let rows = BrowserProcessSampler.sample(rootPID:pid, helperRoot:CommandLine.arguments[2])
struct Tab: Decodable { let id: UUID; let isSleeping: Bool }
struct Stored: Decodable { let tab: Tab }
struct Registry: Decodable { let tabs: [Stored] }
let file = URL(fileURLWithPath:CommandLine.arguments[3])
let values = try file.resourceValues(forKeys:[.fileSizeKey])
guard let size = values.fileSize, size <= 8 * 1024 * 1024 else { fatalError("registry too large") }
let tabs = try JSONDecoder().decode(Registry.self,from:Data(contentsOf:file)).tabs.map(\.tab)
let helpers = rows.filter(\.isHelper)
let readable = rows.allSatisfy { $0.footprintBytes != nil }
let result: [String:Any] = [
 "scope":"read_only_runtime_sample", "stage":CommandLine.arguments[4],
 "time":Date().formatted(.iso8601), "pid":pid, "tab_count":tabs.count,
 "unique_tab_count":Set(tabs.map(\.id)).count, "sleeping_count":tabs.filter(\.isSleeping).count,
 "helper_count":helpers.count,
 "helper_footprint_mb":readable ? helpers.compactMap(\.megabytes).reduce(0,+) as Any : NSNull(),
 "helpers":helpers.map { ["pid":$0.pid,"role":$0.role,"footprint_mb":$0.megabytes as Any? ?? NSNull()] },
 "activeLeaseCount":NSNull(), "verdict":"requires_video_and_close_completion_evidence"
]
print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
SWIFT
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 120 --pid $$)
token=$(printf '%s\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
xcrun swiftc -num-threads 2 App/Sources/Tatwo2/Browser/Diagnostics/BrowserProcessSampler.swift \
  "$WORK/main.swift" -o "$WORK/capture" >&2
"$WORK/capture" "$2" "$3" "$4" "$5"
