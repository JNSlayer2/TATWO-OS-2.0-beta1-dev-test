#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ITERATIONS=20
PAGES="modes,scenarios,workflow,plugins,usage"
BINARY="$ROOT_DIR/.build/debug"
OUT="${TMPDIR:-/tmp}/tatwo-memory-stress-receipt.json"
MODE="dry-run"
SELFTEST=0
ACTION_SELECTOR=""
SLOPE_THRESHOLD_MB=2
RATIO_THRESHOLD=1.15

usage() {
  cat <<'USAGE'
Usage: scripts/tatwo-memory-stress.sh [options]

Options:
  --iterations N              Number of rounds (default: 20)
  --pages a,b,c               Snapshot pages (default: modes,scenarios,workflow,plugins,usage)
  --binary PATH               App binary or containing directory (default: .build/debug)
  --out PATH                  JSON receipt path (default: $TMPDIR/tatwo-memory-stress-receipt.json)
  --slope-threshold-mb MB     Leak slope threshold in MiB/round (default: 2)
  --dry-run                   Write an execution plan without starting the App (default)
  --execute                   Run the snapshot stress test
  --selftest                  Run STABLE, LEAK_SUSPECTED, and INCONCLUSIVE stub checks
  -h, --help                  Show this help
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --iterations)
      (($# >= 2)) || die "--iterations requires a value"
      ITERATIONS="$2"
      shift 2
      ;;
    --pages)
      (($# >= 2)) || die "--pages requires a value"
      PAGES="$2"
      shift 2
      ;;
    --binary)
      (($# >= 2)) || die "--binary requires a value"
      BINARY="$2"
      shift 2
      ;;
    --out)
      (($# >= 2)) || die "--out requires a value"
      OUT="$2"
      shift 2
      ;;
    --slope-threshold-mb)
      (($# >= 2)) || die "--slope-threshold-mb requires a value"
      SLOPE_THRESHOLD_MB="$2"
      shift 2
      ;;
    --dry-run)
      [[ -z "$ACTION_SELECTOR" ]] || die "choose exactly one of --dry-run, --execute, or --selftest"
      ACTION_SELECTOR="dry-run"
      MODE="dry-run"
      shift
      ;;
    --execute)
      [[ -z "$ACTION_SELECTOR" ]] || die "choose exactly one of --dry-run, --execute, or --selftest"
      ACTION_SELECTOR="execute"
      MODE="execute"
      shift
      ;;
    --selftest)
      [[ -z "$ACTION_SELECTOR" ]] || die "choose exactly one of --dry-run, --execute, or --selftest"
      ACTION_SELECTOR="selftest"
      SELFTEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || die "--iterations must be a positive integer"
[[ "$SLOPE_THRESHOLD_MB" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] \
  || die "--slope-threshold-mb must be a non-negative number"
[[ -n "$PAGES" ]] || die "--pages must not be empty"

run_selftest() {
  local temp_root stub stable_json leak_json inconclusive_json
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tatwo-memory-stress-selftest.XXXXXX")"
  trap 'rm -rf "$temp_root"' RETURN
  stub="$temp_root/rss-stub.py"
  stable_json="$temp_root/stable.json"
  leak_json="$temp_root/leak.json"
  inconclusive_json="$temp_root/inconclusive.json"

  cat >"$stub" <<'PY'
#!/usr/bin/env python3
import os
import sys
import time

round_number = int(os.environ["TATWO_MEMORY_STRESS_ROUND"])
curve = os.environ["TATWO_MEMORY_STRESS_TEST_CURVE"]
if curve == "fail" and round_number == 5:
    sys.exit(42)

rss_mib = 32
if curve == "leak":
    rss_mib += round_number * 4

allocation = bytearray(rss_mib * 1024 * 1024)
for offset in range(0, len(allocation), 4096):
    allocation[offset] = 1

snapshot = os.environ["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"]
with open(snapshot, "wb") as handle:
    handle.write(("stub-snapshot-round-%d\n" % round_number).encode("ascii"))
sys.stderr.write("tatwo_panel_snapshot=%s\n" % snapshot)
time.sleep(0.02)
PY
  chmod +x "$stub"

  TATWO_MEMORY_STRESS_TEST_CURVE=stable \
    TATWO_MEMORY_STRESS_TEST_FREE_PERCENT=75 \
    "$0" --execute --iterations 10 --pages modes --binary "$stub" --out "$stable_json" \
    >/dev/null
  TATWO_MEMORY_STRESS_TEST_CURVE=leak \
    TATWO_MEMORY_STRESS_TEST_FREE_PERCENT=75 \
    "$0" --execute --iterations 10 --pages modes --binary "$stub" --out "$leak_json" \
    >/dev/null
  TATWO_MEMORY_STRESS_TEST_CURVE=fail \
    TATWO_MEMORY_STRESS_TEST_FREE_PERCENT=75 \
    "$0" --execute --iterations 10 --pages modes --binary "$stub" --out "$inconclusive_json" \
    >/dev/null

  python3 - "$stable_json" "$leak_json" "$inconclusive_json" <<'PY'
import json
import sys

expected = ("STABLE", "LEAK_SUSPECTED", "INCONCLUSIVE")
for path, wanted in zip(sys.argv[1:], expected):
    with open(path, encoding="utf-8") as handle:
        receipt = json.load(handle)
    actual = receipt["result"]["classification"]
    conclusion = receipt["result"]["conclusion"]
    if actual != wanted:
        raise SystemExit("SELFTEST %s: FAIL (got %s): %s" % (wanted, actual, conclusion))
    if wanted == "INCONCLUSIVE":
        failed_round = next((item for item in receipt["rounds"] if item["round"] == 5), None)
        if (
            failed_round is None
            or failed_round["status"] != "failed"
            or receipt["result"]["failed_rounds"] != [5]
        ):
            raise SystemExit("SELFTEST INCONCLUSIVE: FAIL (failed round 5 was not preserved)")
    print("SELFTEST %s: PASS — %s" % (wanted, conclusion))
print("SELFTEST: PASS (stub binary only; real App was not started)")
PY
}

if ((SELFTEST)); then
  run_selftest
  exit 0
fi

python3 - "$MODE" "$ITERATIONS" "$PAGES" "$BINARY" "$OUT" \
  "$SLOPE_THRESHOLD_MB" "$RATIO_THRESHOLD" "$ROOT_DIR" <<'PY'
import datetime
import json
import math
import os
import pathlib
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import time

mode, iterations_raw, pages_raw, binary_raw, out_raw, slope_raw, ratio_raw, root_raw = sys.argv[1:]
iterations = int(iterations_raw)
slope_threshold_mib = float(slope_raw)
ratio_threshold = float(ratio_raw)
root = pathlib.Path(root_raw)
out_path = pathlib.Path(out_raw).expanduser()
if not out_path.is_absolute():
    out_path = pathlib.Path.cwd() / out_path

pages = [item.strip().lower() for item in pages_raw.split(",")]
allowed_pages = {
    "chat", "usage", "modes", "scenarios",
    "compatibility", "plugins", "devices", "workflow",
}
invalid_pages = [page for page in pages if page not in allowed_pages]
if invalid_pages:
    raise SystemExit(
        "error: unsupported --pages value(s): %s; allowed: %s"
        % (", ".join(invalid_pages), ", ".join(sorted(allowed_pages)))
    )
duplicate_pages = sorted({page for page in pages if pages.count(page) > 1})
if duplicate_pages:
    raise SystemExit("error: duplicate --pages value(s): %s" % ", ".join(duplicate_pages))

binary = pathlib.Path(binary_raw).expanduser()
if not binary.is_absolute():
    binary = pathlib.Path.cwd() / binary
if binary.is_dir() or binary_raw.endswith(os.sep) or binary.name in (".build", "debug"):
    binary = binary / "TatwoUltraworkMac"

created_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
def display_path(path, repo_root):
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError:
        return "<external>/%s" % path.name

criteria = {
    "minimum_samples": 10,
    "slope_threshold_mib_per_round": slope_threshold_mib,
    "later_to_earlier_ratio_threshold": ratio_threshold,
    "leak_suspected": (
        "slope > %.3f MiB/round AND later-half mean > earlier-half mean × %.3f"
        % (slope_threshold_mib, ratio_threshold)
    ),
    "stable": (
        "slope <= %.3f MiB/round AND later/earlier ratio <= %.3f"
        % (slope_threshold_mib, ratio_threshold)
    ),
    "inconclusive": (
        "fewer than 10 rounds, any failed round, unavailable required current "
        "swap-used bytes, or mixed threshold signals"
    ),
    "pressure_abort": "memory_pressure free percentage < 20",
    "half_split": "equal-size outer halves; the midpoint sample is excluded when N is odd",
}

receipt = {
    "schema": "TatwoMemoryStressReceiptV1",
    "created_at": created_at,
    "mode": mode,
    "configuration": {
        "iterations": iterations,
        "pages": pages,
        "binary": display_path(binary, root),
        "output_file": out_path.name,
        "process_timeout_seconds": 120,
        "operation_scope": (
            "Repeated fresh snapshot-export processes sharing one run-isolated formal state. "
            "This detects cross-operation peak-RSS trends; it is not proof of a long-lived "
            "single-process heap leak."
        ),
        "isolation": [
            "one run-level HOME",
            "one run-level CODEX_HOME",
            "one run-level TATWO_ULTRAWORK_APP_SUPPORT",
            "one run-level TATWO_ULTRAWORK_STATE_DIR",
            "one run-level TMPDIR",
        ],
        "network_policy": (
            "The harness requests no network calls, inherits no proxy/auth/session variables, "
            "and disables live probes. This is not an OS-level proof that an arbitrary supplied "
            "binary cannot attempt networking."
        ),
    },
    "criteria": criteria,
    "sampler": None,
    "rounds": [],
    "regression": None,
    "result": None,
}

def atomic_write(payload):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = out_path.with_name(out_path.name + ".tmp.%d" % os.getpid())
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, out_path)

if mode == "dry-run":
    receipt["sampler"] = {
        "selected": "not_selected_in_dry_run",
        "preference": ["/usr/bin/time -l", "wait4/getrusage per child"],
    }
    receipt["result"] = {
        "classification": "DRY_RUN",
        "conclusion": (
            "DRY_RUN: planned %d rounds × %d pages; no App process was started. "
            "Execute explicitly with --execute."
            % (iterations, len(pages))
        ),
        "scope_note": (
            "The planned execution uses repeated fresh snapshot-export processes sharing "
            "one run-isolated state; it is not a long-lived single-process heap test."
        ),
    }
    atomic_write(receipt)
    print(receipt["result"]["conclusion"])
    print("receipt=%s" % out_path)
    raise SystemExit(0)

if not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit("error: executable App binary not found: %s" % binary)

work_root = pathlib.Path(tempfile.mkdtemp(prefix="tatwo-memory-stress-"))
run_home = work_root / "home"
run_codex_home = work_root / "codex-home"
run_app_support = work_root / "app-support"
run_state = run_app_support / "state"
run_tmp = work_root / "tmp"
artifacts_root = work_root / "artifacts"
for isolated_directory in (
    run_home, run_codex_home, run_app_support, run_state, run_tmp, artifacts_root
):
    isolated_directory.mkdir(parents=True, exist_ok=True)
test_curve = os.environ.get("TATWO_MEMORY_STRESS_TEST_CURVE")
pressure_fixture = (
    os.environ.get("TATWO_MEMORY_STRESS_TEST_FREE_PERCENT")
    if test_curve is not None
    else None
)
safe_base_env = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "C",
    "LC_ALL": "C",
    "HOME": str(run_home),
    "CFFIXED_USER_HOME": str(run_home),
    "CODEX_HOME": str(run_codex_home),
    "PWD": str(run_home),
    "OLDPWD": str(run_home),
    "TMPDIR": str(run_tmp),
    "USER": "tatwo-memory-stress",
    "LOGNAME": "tatwo-memory-stress",
    "SHELL": "/bin/sh",
    "TATWO_ULTRAWORK_APP_SUPPORT": str(run_app_support),
    "TATWO_ULTRAWORK_STATE_DIR": str(run_state),
    "TATWO_ULTRAWORK_EXPORT_LIVE_USAGE": "0",
    "TATWO_ULTRAWORK_EXPORT_LIVE_GATEWAY": "0",
    "TATWO_ULTRAWORK_LIVE_ENV_SCAN": "0",
}
if test_curve is not None:
    safe_base_env["TATWO_MEMORY_STRESS_TEST_CURVE"] = test_curve

def cleanup():
    shutil.rmtree(work_root, ignore_errors=True)

def select_sampler():
    metrics_path = work_root / "time-probe.metrics"
    child_stderr_path = work_root / "time-probe.stderr"
    try:
        with child_stderr_path.open("wb") as child_stderr:
            probe = subprocess.run(
            ["/usr/bin/time", "-l", "-o", str(metrics_path), "/usr/bin/true"],
            stdout=subprocess.PIPE,
            stderr=child_stderr,
            timeout=10,
            )
        metrics = metrics_path.read_text(encoding="utf-8", errors="replace") if metrics_path.exists() else ""
        match = re.search(r"(?m)^\s*(\d+)\s+maximum resident set size\s*$", metrics)
        if probe.returncode == 0 and match:
            return {
                "selected": "bsd_time_l",
                "peak_rss_unit": "bytes",
                "fallback": "wait4/getrusage per child",
                "probe": "passed with -o metrics separation",
            }
        reason = "exit=%d; maxrss_field=%s" % (probe.returncode, "present" if match else "missing")
    except (OSError, subprocess.TimeoutExpired) as error:
        reason = "unavailable: %s" % error
    return {
        "selected": "wait4_getrusage",
        "peak_rss_unit": "bytes on macOS",
        "fallback_reason": reason,
        "scope": "fresh direct child per page; ru_maxrss is not reused across page launches",
    }

def parse_size_to_bytes(value, unit):
    factors = {
        "K": 1024,
        "M": 1024 ** 2,
        "G": 1024 ** 3,
        "T": 1024 ** 4,
    }
    return int(float(value) * factors[unit.upper()])

def pressure_sample():
    sample = {
        "captured_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
        "free_percent": None,
        "memory_pressure_status": "unavailable",
        "swap": None,
    }
    if pressure_fixture is not None:
        sample["free_percent"] = float(pressure_fixture)
        sample["memory_pressure_status"] = "selftest_fixture"
        sample["swap"] = {
            "kind": "selftest_fixture",
            "used_bytes": None,
            "source": "selftest does not inspect host pressure or swap",
        }
        return sample
    try:
        result = subprocess.run(
            ["/usr/bin/memory_pressure", "-Q"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
            timeout=10,
        )
        match = re.search(
            r"(?m)^System-wide memory free percentage:\s*(\d+(?:\.\d+)?)%\s*$",
            result.stdout,
        )
        if result.returncode == 0 and match:
            sample["free_percent"] = float(match.group(1))
            sample["memory_pressure_status"] = "ok"
        else:
            sample["memory_pressure_status"] = "failed_exit_%d" % result.returncode
    except (OSError, subprocess.TimeoutExpired):
        pass

    try:
        swap_result = subprocess.run(
            ["/usr/sbin/sysctl", "vm.swapusage"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
            timeout=10,
        )
        match = re.search(
            r"(?m)^vm\.swapusage:.*\bused\s*=\s*([0-9.]+)([KMGT])(?:\s|$)",
            swap_result.stdout,
        )
        if swap_result.returncode == 0 and match:
            sample["swap"] = {
                "kind": "swap_used_bytes",
                "used_bytes": parse_size_to_bytes(match.group(1), match.group(2)),
                "source": "sysctl vm.swapusage",
            }
            return sample
    except (OSError, subprocess.TimeoutExpired):
        pass

    try:
        vm_result = subprocess.run(
            ["/usr/bin/vm_stat"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
            timeout=10,
        )
        swapins = re.search(r"(?m)^Swapins:\s*(\d+)\.", vm_result.stdout)
        swapouts = re.search(r"(?m)^Swapouts:\s*(\d+)\.", vm_result.stdout)
        page_size = re.search(r"page size of\s+(\d+)\s+bytes", vm_result.stdout)
        if vm_result.returncode == 0 and swapins and swapouts:
            sample["swap"] = {
                "kind": "vm_stat_cumulative_pages",
                "used_bytes": None,
                "swapins_pages": int(swapins.group(1)),
                "swapouts_pages": int(swapouts.group(1)),
                "page_size_bytes": int(page_size.group(1)) if page_size else None,
                "source": "vm_stat fallback; cumulative activity, not current swap-used bytes",
                "measurement_error": "current swap-used bytes unavailable",
            }
        else:
            sample["swap"] = {
                "kind": "unavailable",
                "used_bytes": None,
                "source": "sysctl denied/unavailable and vm_stat fields missing",
                "measurement_error": "current swap-used bytes unavailable",
            }
    except (OSError, subprocess.TimeoutExpired):
        sample["swap"] = {
            "kind": "unavailable",
            "used_bytes": None,
            "source": "sysctl and vm_stat unavailable",
            "measurement_error": "current swap-used bytes unavailable",
        }
    return sample

def terminate_process_group(process):
    try:
        os.killpg(process.pid, 15)
    except ProcessLookupError:
        return
    time.sleep(0.2)
    try:
        os.killpg(process.pid, 9)
    except ProcessLookupError:
        pass

def run_wait4(command, env, cwd, stdout_path, stderr_path, timeout_seconds=120):
    started = time.monotonic()
    with stdout_path.open("wb") as stdout_handle, stderr_path.open("wb") as stderr_handle:
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            env=env,
            stdout=stdout_handle,
            stderr=stderr_handle,
            start_new_session=True,
        )
        deadline = started + timeout_seconds
        timed_out = False
        while True:
            waited_pid, status, usage = os.wait4(process.pid, os.WNOHANG)
            if waited_pid == process.pid:
                process.returncode = os.waitstatus_to_exitcode(status)
                break
            if time.monotonic() >= deadline:
                timed_out = True
                terminate_process_group(process)
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
                break
            time.sleep(0.05)
    wall = time.monotonic() - started
    maxrss = usage.ru_maxrss
    if sys.platform != "darwin":
        maxrss *= 1024
    return (124 if timed_out else process.returncode), int(maxrss), wall, timed_out

def run_time_l(command, env, cwd, stdout_path, stderr_path, metrics_path, timeout_seconds=120):
    started = time.monotonic()
    with stdout_path.open("wb") as stdout_handle, stderr_path.open("wb") as stderr_handle:
        process = subprocess.Popen(
            ["/usr/bin/time", "-l", "-o", str(metrics_path)] + command,
            cwd=str(cwd),
            env=env,
            stdout=stdout_handle,
            stderr=stderr_handle,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            terminate_process_group(process)
            process.wait()
    wall = time.monotonic() - started
    text = metrics_path.read_text(encoding="utf-8", errors="replace") if metrics_path.exists() else ""
    match = re.search(r"(?m)^\s*(\d+)\s+maximum resident set size\s*$", text)
    return (
        124 if timed_out else process.returncode,
        int(match.group(1)) if match else None,
        wall,
        timed_out,
    )

def png_dimensions(path):
    try:
        header = path.read_bytes()[:24]
    except OSError:
        return None
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        return None
    return (
        int.from_bytes(header[16:20], "big"),
        int.from_bytes(header[20:24], "big"),
    )

receipt["sampler"] = select_sampler()
failed_rounds = []
swap_used_missing_rounds = []
aborted_pressure = None

try:
    for round_number in range(1, iterations + 1):
        pressure = pressure_sample()
        round_sample = {
            "round": round_number,
            "pressure_before": pressure,
            "pages": [],
            "peak_rss_bytes": None,
            "peak_rss_mib": None,
            "wall_time_seconds": None,
            "output_file_size_bytes": None,
            "status": "pending",
        }

        if pressure["free_percent"] is None:
            round_sample["status"] = "failed"
            round_sample["failure"] = "memory_pressure free percentage unavailable"
            receipt["rounds"].append(round_sample)
            failed_rounds.append(round_number)
            break

        if pressure["free_percent"] < 20:
            round_sample["status"] = "aborted_pressure"
            round_sample["failure"] = (
                "free memory %.3f%% is below the 20%% stop threshold"
                % pressure["free_percent"]
            )
            receipt["rounds"].append(round_sample)
            aborted_pressure = pressure["free_percent"]
            break

        if (
            pressure.get("swap", {}).get("kind") != "selftest_fixture"
            and pressure.get("swap", {}).get("used_bytes") is None
        ):
            swap_used_missing_rounds.append(round_number)

        round_root = artifacts_root / ("round-%03d" % round_number)
        round_root.mkdir(parents=True)
        round_failed = False

        for page in pages:
            page_root = round_root / page
            page_root.mkdir(parents=True, exist_ok=True)
            snapshot = page_root / ("%s.png" % page)
            stdout_log = page_root / "stdout.log"
            stderr_log = page_root / "stderr.log"
            time_metrics_log = page_root / "time.metrics"

            env = safe_base_env.copy()
            env.update({
                "TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT": str(snapshot),
                "TATWO_ULTRAWORK_EXPORT_TAB": page,
                "TATWO_ULTRAWORK_INITIAL_PAGE": page,
                "TATWO_ULTRAWORK_PANEL_INITIAL_PAGE": page,
                "TATWO_ULTRAWORK_EXPORT_LIVE_USAGE": "0",
                "TATWO_ULTRAWORK_EXPORT_LIVE_GATEWAY": "0",
                "TATWO_ULTRAWORK_LIVE_ENV_SCAN": "0",
                "TATWO_MEMORY_STRESS_ROUND": str(round_number),
                "TATWO_MEMORY_STRESS_PAGE": page,
            })

            command = [str(binary)]
            execution_error = None
            timed_out = False
            started = time.monotonic()
            try:
                if receipt["sampler"]["selected"] == "bsd_time_l":
                    exit_code, peak_rss, wall, timed_out = run_time_l(
                        command, env, run_home, stdout_log, stderr_log, time_metrics_log
                    )
                else:
                    exit_code, peak_rss, wall, timed_out = run_wait4(
                        command, env, run_home, stdout_log, stderr_log
                    )
            except Exception as error:
                exit_code = -1
                peak_rss = None
                wall = time.monotonic() - started
                execution_error = type(error).__name__

            output_size = snapshot.stat().st_size if snapshot.is_file() else None
            dimensions = png_dimensions(snapshot) if snapshot.is_file() else None
            stderr_text = (
                stderr_log.read_text(encoding="utf-8", errors="replace")
                if stderr_log.is_file()
                else ""
            )
            expected_success_marker = "tatwo_panel_snapshot=%s" % snapshot
            success_marker_present = expected_success_marker in stderr_text.splitlines()
            failure_marker_present = any(
                marker in stderr_text
                for marker in ("tatwo_snapshot_failed=", "tatwo_panel_snapshot_failed=")
            )
            failure = None
            if execution_error is not None:
                failure = "process sampling exception: %s" % execution_error
            elif timed_out:
                failure = "process exceeded 120-second timeout"
            elif exit_code != 0:
                failure = "process exited with status %d" % exit_code
            elif peak_rss is None:
                failure = "peak RSS sampler returned no value"
            elif output_size is None or output_size <= 0:
                failure = "snapshot output missing or empty"
            elif failure_marker_present:
                failure = "snapshot exporter reported a failure marker"
            elif not success_marker_present:
                failure = "snapshot exporter success marker missing"
            elif test_curve is None and dimensions != (520, 620):
                failure = "snapshot dimensions are not the required 520x620 panel size"

            page_sample = {
                "page": page,
                "process_exit_code": exit_code,
                "peak_rss_bytes": peak_rss,
                "peak_rss_mib": round(peak_rss / (1024 ** 2), 6) if peak_rss is not None else None,
                "wall_time_seconds": round(wall, 6),
                "output_file_size_bytes": output_size,
                "snapshot_dimensions": (
                    {"width": dimensions[0], "height": dimensions[1]}
                    if dimensions is not None
                    else None
                ),
                "snapshot_label": "round-%03d/%s/%s.png" % (round_number, page, page),
                "snapshot_retained": False,
                "success_marker_present": success_marker_present,
                "failure_marker_present": failure_marker_present,
                "timed_out": timed_out,
                "status": "failed" if failure else "ok",
            }
            if failure:
                page_sample["failure"] = failure
                round_failed = True
            round_sample["pages"].append(page_sample)

        valid_rss = [item["peak_rss_bytes"] for item in round_sample["pages"] if item["peak_rss_bytes"] is not None]
        valid_sizes = [
            item["output_file_size_bytes"]
            for item in round_sample["pages"]
            if item["output_file_size_bytes"] is not None
        ]
        round_sample["peak_rss_bytes"] = max(valid_rss) if valid_rss else None
        round_sample["peak_rss_mib"] = (
            round(round_sample["peak_rss_bytes"] / (1024 ** 2), 6)
            if round_sample["peak_rss_bytes"] is not None
            else None
        )
        round_sample["wall_time_seconds"] = round(
            sum(item["wall_time_seconds"] for item in round_sample["pages"]), 6
        )
        round_sample["output_file_size_bytes"] = sum(valid_sizes) if valid_sizes else None
        round_sample["status"] = "failed" if round_failed else "ok"
        receipt["rounds"].append(round_sample)
        if round_failed:
            failed_rounds.append(round_number)
finally:
    cleanup()

successful = [
    item for item in receipt["rounds"]
    if item["status"] == "ok" and item["peak_rss_bytes"] is not None
]

def regression(samples):
    count = len(samples)
    if count < 2:
        return {
            "sample_count": count,
            "slope_bytes_per_round": None,
            "slope_mib_per_round": None,
            "intercept_bytes": None,
            "earlier_half_mean_bytes": None,
            "later_half_mean_bytes": None,
            "later_to_earlier_ratio": None,
            "r_squared": None,
        }
    xs = [float(item["round"]) for item in samples]
    ys = [float(item["peak_rss_bytes"]) for item in samples]
    x_mean = sum(xs) / count
    y_mean = sum(ys) / count
    denominator = sum((x - x_mean) ** 2 for x in xs)
    slope = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / denominator
    intercept = y_mean - slope * x_mean
    predictions = [intercept + slope * x for x in xs]
    ss_res = sum((y - predicted) ** 2 for y, predicted in zip(ys, predictions))
    ss_tot = sum((y - y_mean) ** 2 for y in ys)
    r_squared = 1.0 - (ss_res / ss_tot) if ss_tot else 1.0
    midpoint = count // 2
    earlier = ys[:midpoint]
    later = ys[-midpoint:]
    earlier_mean = sum(earlier) / len(earlier)
    later_mean = sum(later) / len(later)
    ratio = later_mean / earlier_mean if earlier_mean else math.inf
    return {
        "sample_count": count,
        "round_numbers": [item["round"] for item in samples],
        "failed_rounds_excluded": failed_rounds,
        "slope_bytes_per_round": round(slope, 6),
        "slope_mib_per_round": round(slope / (1024 ** 2), 6),
        "intercept_bytes": round(intercept, 6),
        "earlier_half_mean_bytes": round(earlier_mean, 6),
        "later_half_mean_bytes": round(later_mean, 6),
        "later_to_earlier_ratio": round(ratio, 6),
        "r_squared": round(r_squared, 6),
    }

receipt["regression"] = regression(successful)
stats = receipt["regression"]
slope_mib = stats["slope_mib_per_round"]
ratio = stats["later_to_earlier_ratio"]

if aborted_pressure is not None:
    classification = "ABORTED_PRESSURE"
    conclusion = (
        "ABORTED_PRESSURE: memory_pressure free=%.3f%% < 20%%; stopped before launching "
        "that round. Completed rounds=%d/%d; prior failed rounds=%s; leak analysis remains "
        "inconclusive."
        % (aborted_pressure, len(successful), iterations, failed_rounds)
    )
elif len(receipt["rounds"]) < iterations and failed_rounds:
    classification = "INCONCLUSIVE"
    conclusion = (
        "INCONCLUSIVE: round failure prevented completion; failed rounds=%s, "
        "completed samples=%d/%d. Failed rounds were recorded, not omitted."
        % (failed_rounds, len(successful), iterations)
    )
elif failed_rounds:
    classification = "INCONCLUSIVE"
    conclusion = (
        "INCONCLUSIVE: one or more rounds failed (failed rounds=%s); slope=%.3f MiB/round, "
        "later/earlier=%.3f. Failed rounds were recorded, not silently omitted."
        % (failed_rounds, slope_mib or 0.0, ratio or 0.0)
    )
elif swap_used_missing_rounds:
    classification = "INCONCLUSIVE"
    conclusion = (
        "INCONCLUSIVE: required current swap-used bytes were unavailable in rounds=%s; "
        "RSS slope=%.3f MiB/round and later/earlier=%.3f are diagnostic only because the "
        "host-pressure receipt is incomplete."
        % (swap_used_missing_rounds, slope_mib or 0.0, ratio or 0.0)
    )
elif len(successful) < 10:
    classification = "INCONCLUSIVE"
    conclusion = (
        "INCONCLUSIVE: samples=%d < required minimum=10; slope=%s MiB/round, "
        "later/earlier=%s."
        % (
            len(successful),
            "%.3f" % slope_mib if slope_mib is not None else "unavailable",
            "%.3f" % ratio if ratio is not None else "unavailable",
        )
    )
elif slope_mib > slope_threshold_mib and ratio > ratio_threshold:
    classification = "LEAK_SUSPECTED"
    conclusion = (
        "LEAK_SUSPECTED: slope=%.3f MiB/round > threshold=%.3f AND "
        "later/earlier=%.3f > %.3f; samples=%d, failures=0."
        % (slope_mib, slope_threshold_mib, ratio, ratio_threshold, len(successful))
    )
elif slope_mib <= slope_threshold_mib and ratio <= ratio_threshold:
    classification = "STABLE"
    conclusion = (
        "STABLE: slope=%.3f MiB/round <= threshold=%.3f AND "
        "later/earlier=%.3f <= %.3f; samples=%d, failures=0."
        % (slope_mib, slope_threshold_mib, ratio, ratio_threshold, len(successful))
    )
else:
    classification = "INCONCLUSIVE"
    conclusion = (
        "INCONCLUSIVE: mixed leak signals; slope=%.3f MiB/round (threshold %.3f), "
        "later/earlier=%.3f (threshold %.3f); neither two-part verdict matched."
        % (slope_mib, slope_threshold_mib, ratio, ratio_threshold)
    )

receipt["result"] = {
    "classification": classification,
    "conclusion": conclusion,
    "scope_note": (
        "This run repeatedly launched fresh snapshot-export processes against one shared "
        "run-isolated state. It measures cross-operation peak-RSS trend and does not by "
        "itself prove or disprove a leak inside one long-lived App process."
    ),
    "completed_rounds": len(successful),
    "requested_rounds": iterations,
    "failed_rounds": failed_rounds,
    "swap_used_missing_rounds": swap_used_missing_rounds,
}
atomic_write(receipt)
print(conclusion)
print("sampler=%s" % receipt["sampler"]["selected"])
print("receipt=%s" % out_path)
PY
