#!/bin/bash
# W55 / D-B6. Run against a disposable, packaged preview App on the MacBook.
# Requires Accessibility permission for the invoking terminal and Xcode swiftc.
# No install, signing, profile deletion or changes to an already running App.
# Default wait: 25 minutes. TATWO_BROWSER_SLEEP_SECONDS overrides the App threshold
# and uses threshold + 35 seconds here (the runtime checks every 30 seconds).
# stdout: exactly one JSON record. PASS/FAIL and progress: stderr.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --ten-plan ]]; then
    cat <<'PLAN'
W60b: use an authorized disposable CEF candidate/profile, not the working App.
Open exactly 10 tabs using the UI, visiting distinct public sites, then wait for
the selected page to finish loading and native close callbacks to settle.
Capture while Browser is still visible (do not wait for the idle sleep timer):
  bash scripts/browser-perf.sh --capture-ten PID HELPER_ROOT REGISTRY_JSON
Repeat on the same machine/workload before and after W60b. Record the candidate
revision, hash, timestamp and viewport separately; this sampler does not launch,
install, navigate, kill or claim a memory/performance PASS.
RSS uses ri_resident_size; physical footprint is reported separately. A ten-tab
registry does not prove ten browser instances or ten renderer processes.
PLAN
    exit 0
fi
if [[ "${1:-}" == --capture-ten ]]; then
    [[ $# == 4 && "$2" =~ ^[1-9][0-9]*$ ]] || {
        echo 'Usage: browser-perf.sh --capture-ten PID HELPER_ROOT REGISTRY_JSON' >&2; exit 2;
    }
    WORK="$ROOT/.build/w60b/perf"
    mkdir -p "$WORK"
    cat > "$WORK/main.swift" <<'TEN_SWIFT'
import Foundation
import Darwin
let pid = pid_t(CommandLine.arguments[1])!
guard kill(pid, 0) == 0 else { fatalError("candidate not alive/readable") }
struct Tab: Decodable { let isSleeping: Bool }
struct Stored: Decodable { let tab: Tab }
struct Registry: Decodable { let tabs: [Stored] }
let url = URL(fileURLWithPath: CommandLine.arguments[3])
guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 8 * 1024 * 1024 else { fatalError("registry too large") }
let tabs = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url)).tabs.map(\.tab)
guard tabs.count == 10 else { fatalError("expected exactly ten tabs in disposable registry") }
let helpers = BrowserProcessSampler.sample(rootPID: pid, helperRoot: CommandLine.arguments[2]).filter(\.isHelper)
let readable = !helpers.isEmpty && helpers.allSatisfy { $0.residentBytes != nil && $0.footprintBytes != nil }
let result: [String: Any] = [
    "stage": "after_opening_10_tabs", "time": Date().formatted(.iso8601),
    "tab_count": tabs.count, "live_tabs": tabs.filter { !$0.isSleeping }.count,
    "sleeping_tabs": tabs.filter(\.isSleeping).count,
    "helper_count": helpers.count, "renderer_count": helpers.filter { $0.role == "renderer" }.count,
    "helper_rss_mb": readable ? helpers.compactMap(\.residentBytes).reduce(0.0) { $0 + Double($1) / 1_048_576 } as Any : NSNull(),
    "helper_footprint_mb": readable ? helpers.compactMap(\.megabytes).reduce(0, +) as Any : NSNull(),
    "rss_metric": "ri_resident_size", "footprint_metric": "ri_phys_footprint",
    "verdict": "measurement_only_not_acceptance"
]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
TEN_SWIFT
    receipt=$(bash "$ROOT/scripts/tatwo-build-lock.sh" acquire --timeout 120 --pid $$)
    token=$(printf '%s\n' "$receipt" | sed -n 's/^token=//p')
    trap 'bash "$ROOT/scripts/tatwo-build-lock.sh" release --token "$token" >/dev/null' EXIT
    xcrun swiftc -num-threads 2 "$ROOT/App/Sources/Tatwo2/Browser/Diagnostics/BrowserProcessSampler.swift" \
        "$WORK/main.swift" -o "$WORK/capture" >&2
    "$WORK/capture" "$2" "$3" "$4"
    exit 0
fi
APP="${1:-}"
WORK="$ROOT/.build/w55/perf"
RESULT_EMITTED=0
APP_PID=""
finish() {
    local code=$?
    if [[ -n "$APP_PID" ]] && jobs -pr | grep -qx "$APP_PID"; then
        kill -TERM "$APP_PID" 2>/dev/null || true
    fi
    if [[ "$RESULT_EMITTED" == 0 ]]; then
        printf '{"status":"FAIL","error":"measurement_incomplete","startup_ms":null,"helper_rss_mb":null}\n'
        printf 'FAIL: measurement incomplete (see stderr)\n' >&2
    fi
    return "$code"
}
trap finish EXIT
[[ "$(uname -s)" == Darwin && -d "$APP/Contents/MacOS" ]] || {
    printf 'Usage: %s /path/to/disposable-preview.app\n' "$0" >&2; exit 2;
}
APP="$(cd "$APP" && pwd)"
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")
[[ "$EXECUTABLE" != */* && -x "$APP/Contents/MacOS/$EXECUTABLE" ]] || exit 2
# Refuse to attach to/terminate an existing process with the same executable.
if /usr/bin/pgrep -x "$EXECUTABLE" >/dev/null; then
    printf 'App already running; use a closed, disposable preview App.\n' >&2; exit 2
fi
mkdir -p "$WORK"
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import Darwin
let pid = pid_t(CommandLine.arguments[1])!
let samples = BrowserProcessSampler.sample(rootPID: pid, helperRoot: CommandLine.arguments[2])
let helpers = samples.filter(\.isHelper)
let readable = !helpers.isEmpty && helpers.allSatisfy { $0.footprintBytes != nil }
let mb = helpers.compactMap(\.megabytes).reduce(0, +)
let startup = Double(CommandLine.arguments[3])!
struct Tab: Decodable { let url: URL?; let isSleeping: Bool; let createdAt: Date }
struct StoredTab: Decodable { let tab: Tab }
struct Registry: Decodable { let tabs: [StoredTab] }
let launchedAt = Date(timeIntervalSince1970: Double(CommandLine.arguments[6])!)
let registry = try? JSONDecoder().decode(Registry.self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5])))
let created = registry?.tabs.map(\.tab).filter { $0.createdAt >= launchedAt && $0.url?.host == "example.com" }
let sleepingVerified = created?.count == 5 && created?.allSatisfy(\.isSleeping) == true
let status = readable && sleepingVerified && startup <= 1500 && mb <= 400 ? "PASS" : "FAIL"
let result: [String: Any] = [
    "status": status, "startup_ms": startup,
    "helper_rss_mb": readable ? mb as Any : NSNull(),
    "helper_count": helpers.count, "metric": "ri_phys_footprint",
    "startup_target_ms": 1500, "helper_target_mb": 400,
    "wait_seconds": Double(CommandLine.arguments[4])!,
    "expected_sleeping_tabs": 5,
    "sleep_state_verified": sleepingVerified,
    "readiness_proxy": "AX tab title Example Domain"
]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
fputs("\(status): tab title \(Int(startup)) ms / 1500 ms; helper \(readable ? String(format: "%.1f", mb) : "unavailable") MB / 400 MB; five sleepers verified=\(sleepingVerified)\n", stderr)
exit(status == "PASS" ? 0 : 1)
SWIFT
xcrun swiftc -num-threads 2 "$ROOT/App/Sources/Tatwo2/Browser/Diagnostics/BrowserProcessSampler.swift" \
    "$WORK/main.swift" -o "$WORK/sample" >&2
WAIT=1500
if [[ -n "${TATWO_BROWSER_SLEEP_SECONDS:-}" ]]; then
    WAIT=$(/usr/bin/awk -v s="$TATWO_BROWSER_SLEEP_SECONDS" 'BEGIN {
        if (s !~ /^[0-9]+([.][0-9]+)?$/ || s+0 <= 0 || s+0 > 86400) exit 2;
        printf "%.0f", s+35
    }')
fi
LAUNCHED_AT=$(date +%s)
TATWO_BROWSER_WORKSPACE_PREVIEW=1 "$APP/Contents/MacOS/$EXECUTABLE" >"$WORK/app.log" 2>&1 &
APP_PID=$!
export TATWO_PERF_PID="$APP_PID"
cat > "$WORK/measure.applescript" <<'APPLESCRIPT'
use framework "Foundation"
use scripting additions
property windowName : "Tatwo Ultrawork OS"
on findButton(p, labels)
    tell application "System Events"
        repeat with e in (entire contents of window windowName of p)
            try
                if role of e is "AXButton" and name of e is in labels then return e
            end try
        end repeat
    end tell
    error "Required AX button missing"
end findButton
on openTab(p)
    tell application "System Events" to click my findButton(p, {"新分頁", "＋ 新分頁", "+ 新分頁"})
end openTab
on navigate(p)
    tell application "System Events"
        -- Reference from W47; fresh lookup after every tab/UI change.
        set addressField to text field 1 of group 1 of splitter group 1 of group 1 of splitter group 1 of group 1 of window windowName of p
        set value of addressField to "https://example.com"
        perform action "AXConfirm" of addressField
    end tell
end navigate
on waitForTitle(p, expectedCount)
    set deadline to (current application's NSProcessInfo's processInfo()'s systemUptime()) + 30
    repeat
        tell application "System Events"
            set matches to 0
            repeat with e in (entire contents of window windowName of p)
                try
                    if role of e is "AXButton" and name of e is "Example Domain" then set matches to matches + 1
                end try
            end repeat
            if matches >= expectedCount then return
        end tell
        if (current application's NSProcessInfo's processInfo()'s systemUptime()) > deadline then error "Example Domain title timeout"
        delay 0.05
    end repeat
end waitForTitle
on run
    set pid to (system attribute "TATWO_PERF_PID") as integer
    tell application "System Events"
        repeat 120 times
            if exists (first application process whose unix id is pid) then
                set p to first application process whose unix id is pid
                if exists window windowName of p then exit repeat
            end if
            delay 0.25
        end repeat
        set frontmost of p to true
        click my findButton(p, {"Browser", "Browser work space"})
    end tell
    delay 0.5
    -- Engine warm-up is excluded: D-B6 specifies an already-started engine.
    my openTab(p)
    my navigate(p)
    my waitForTitle(p, 1)
    tell application "System Events" to keystroke "w" using command down
    delay 0.5
    -- No pre-existing Example Domain button may satisfy the measured title.
    tell application "System Events"
        repeat with e in (entire contents of window windowName of p)
            try
                if role of e is "AXButton" and name of e is "Example Domain" then error number -27001
            on error number -27001
                error "Use an empty disposable Browser space"
            end try
        end repeat
    end tell
    set measuredButton to my findButton(p, {"新分頁", "＋ 新分頁", "+ 新分頁"})
    set started to current application's NSProcessInfo's processInfo()'s systemUptime()
    tell application "System Events" to click measuredButton
    my navigate(p)
    my waitForTitle(p, 1)
    set elapsedMS to ((current application's NSProcessInfo's processInfo()'s systemUptime()) - started) * 1000
    -- Five further opens: four loaded tabs plus a blank sentinel. Close the
    -- sentinel, then leave Browser so the five loaded tabs can ALL sleep.
    repeat with expectedCount from 2 to 5
        my openTab(p)
        my navigate(p)
        my waitForTitle(p, expectedCount)
    end repeat
    my openTab(p)
    tell application "System Events"
        keystroke "w" using command down
        click my findButton(p, {"Chat"})
    end tell
    return elapsedMS
end run
APPLESCRIPT
STARTUP_MS=$(/usr/bin/osascript "$WORK/measure.applescript")
printf 'Waiting %s seconds for five background tabs and the 30-second sleep timer…\n' "$WAIT" >&2
sleep "$WAIT"
kill -0 "$APP_PID" || exit 1
set +e
RESULT=$("$WORK/sample" "$APP_PID" "$APP/Contents/Frameworks" "$STARTUP_MS" "$WAIT" \
    "${TATWO_BROWSER_TABS_FILE:-$HOME/Library/Application Support/TATWO OS/Browser/tabs.json}" "$LAUNCHED_AT")
CODE=$?
set -e
if [[ -n "$RESULT" ]]; then
    RESULT_EMITTED=1
    printf '%s\n' "$RESULT"
fi
exit "$CODE"
