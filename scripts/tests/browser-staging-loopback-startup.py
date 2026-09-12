#!/usr/bin/env python3
"""Headless unavailable-bridge startup/cache receipts; never launches an App."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".build-browser/c2-validation"
BRIDGE = ROOT / "Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge"
KEYS = (
    "TATWO_STAGING_ALLOW_BROWSER_LOOPBACK",
    "TATWO_STAGING_SCRATCH_HOME",
    "TATWO_STAGING_BROWSER_LOOPBACK_PORT",
)


def memory_gate():
    while True:
        stats = subprocess.check_output(["vm_stat"], text=True)
        page = int(re.search(r"page size of (\d+)", stats)[1])
        available = page * sum(
            int(re.search(r"Pages " + key + r":\s+(\d+)", stats)[1])
            for key in ("free", "inactive")
        )
        print(f"C2_STARTUP_MEMORY free_plus_inactive_gib={available / 2**30:.3f}", flush=True)
        if available >= 2 * 2**30:
            return
        time.sleep(60)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    binaries = {}
    for kind, identity in (
        ("staging", "ai.tatwo.tatwo2.c2"),
        ("production", "ai.tatwo.tatwo2"),
    ):
        memory_gate()
        info = OUT / f"startup-{kind}-fixture.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": identity}))
        binary = OUT / f"startup-{kind}-probe"
        # Embedded CLI Info.plist provides NSBundle identity without an App bundle.
        command = [
            "nice", "-n", "10", "xcrun", "clang", "-fobjc-arc", "-fblocks",
            "-DTATWO_TEST_STUB_STARTUP", "-framework", "Foundation", "-framework", "AppKit",
            "-I", str(BRIDGE / "include"),
            str(ROOT / "scripts/tests/browser-staging-loopback-policy.m"),
            str(BRIDGE / "TatwoCEFBridgeUnavailable.m"),
            f"-Wl,-sectcreate,__TEXT,__info_plist,{info}", "-o", str(binary),
        ]
        with (OUT / f"startup-{kind}-compile.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        binaries[kind] = binary

    base = {key: value for key, value in os.environ.items() if key not in KEYS}
    enabled = {KEYS[0]: "1", KEYS[1]: "/fixture/home"}
    cases = [
        ("staging-no-environment", "staging", {}, 0),
        ("staging-no-isolation", "staging", {KEYS[0]: "1"}, 0),
        ("staging-whitespace-isolation", "staging", {**enabled, KEYS[1]: " \n\t"}, 0),
        ("staging-wrong-flag", "staging", {**enabled, KEYS[0]: "true"}, 0),
        ("production-all-flags", "production", enabled, 0),
        ("staging-default-port", "staging", enabled, 8765),
        ("staging-custom-port", "staging", {**enabled, KEYS[2]: "9001"}, 9001),
        ("staging-invalid-port", "staging", {**enabled, KEYS[2]: ""}, 0),
    ]
    receipts = []
    for name, kind, environment, expected in cases:
        result = subprocess.run(
            [str(binaries[kind]), str(expected)],
            env={**base, **environment}, text=True, capture_output=True, check=True,
        )
        markers = [
            line for line in result.stderr.splitlines()
            if line.startswith("browser_staging_loopback=")
        ]
        wanted = [f"browser_staging_loopback=enabled port={expected}"] if expected else []
        if markers != wanted:
            raise AssertionError(f"{name}: unexpected startup marker count/value")
        if "CEF_STAGING_LOOPBACK_STARTUP_PASS" not in result.stdout:
            raise AssertionError(f"{name}: missing assertion receipt")
        receipts.append({"case": name, "expected_port": expected, "startup_markers": markers,
                         "receipt": result.stdout.strip(), "exit": result.returncode})
        print(f"C2_STARTUP_PASS case={name} expected_port={expected}", flush=True)
    (OUT / "startup-summary.json").write_text(json.dumps(receipts, indent=2) + "\n")
    print(f"C2_STARTUP_SUITE_PASS cases={len(receipts)}", flush=True)


if __name__ == "__main__":
    main()
