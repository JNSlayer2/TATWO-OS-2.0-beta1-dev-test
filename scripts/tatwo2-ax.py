#!/usr/bin/env python3
"""Small macOS Accessibility driver for Tatwo2 acceptance runs (stdlib only)."""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path


def osa(script: str, *args: str, timeout: int = 20) -> str:
    completed = subprocess.run(
        ["osascript", "-l", "AppleScript", "-e", script, *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if completed.returncode:
        raise RuntimeError(completed.stderr.strip() or completed.stdout.strip())
    return completed.stdout.strip()


_COMMON = r'''
on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        set frontmost of targetProcess to true
    end tell
end run
'''


def focus(pid: int) -> None:
    osa(_COMMON, str(pid))


def key(pid: int, key_name: str, command: bool = False) -> None:
    modifier = " using command down" if command else ""
    osa(
        r'''on run argv
    set targetPID to item 1 of argv as integer
    set keyName to item 2 of argv
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        set frontmost of targetProcess to true
        tell targetProcess to keystroke keyName''' + modifier + r'''
    end tell
end run''',
        str(pid), key_name,
    )


def dump_tree(pid: int, destination: Path) -> str:
    script = r'''on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        set axRows to {}
        try
            repeat with e in (entire contents of window 1 of targetProcess)
                try
                    set end of axRows to ((role of e as text) & " | " & (name of e as text) & " | " & (description of e as text) & " | " & (value of e as text))
                end try
            end repeat
        on error errMsg
            set end of axRows to "AX_ERROR | " & errMsg
        end try
        return axRows as text
    end tell
end run'''
    try:
        value = osa(script, str(pid), timeout=30)
    except Exception as exc:  # Preserve the actual AX failure in the artifact.
        value = f"AX_DUMP_ERROR | {exc}"
    destination.write_text(value + "\n", encoding="utf-8")
    return value


def static_text(pid: int) -> str:
    script = r'''on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        set axRows to {}
        repeat with e in (entire contents of window 1 of targetProcess)
            try
                if role of e is "AXStaticText" then set end of axRows to (value of e as text)
            end try
        end repeat
        return axRows as text
    end tell
end run'''
    return osa(script, str(pid), timeout=30)


def click_named(pid: int, needles: list[str]) -> bool:
    # AXName and AXDescription differ by SwiftUI/control type, so examine both.
    joined = "|||".join(needles)
    script = r'''on run argv
    set targetPID to item 1 of argv as integer
    set AppleScript's text item delimiters to "|||"
    set needles to items of item 2 of argv
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        repeat with e in (entire contents of window 1 of targetProcess)
            try
                set haystack to ((name of e as text) & " " & (description of e as text) & " " & (value of e as text))
                repeat with needle in needles
                    if haystack contains (needle as text) then
                        if (role of e is "AXButton") or (role of e is "AXPopUpButton") or (role of e is "AXMenuButton") then
                            perform action "AXPress" of e
                            return "clicked"
                        end if
                    end if
                end repeat
            end try
        end repeat
    end tell
    return "missing"
end run'''
    return osa(script, str(pid), joined) == "clicked"


def set_composer(pid: int, message: str) -> bool:
    # Do not use keystroke for text: Taiwanese IME can swallow it.
    script = r'''on run argv
    set targetPID to item 1 of argv as integer
    set messageText to item 2 of argv
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        repeat with e in (entire contents of window 1 of targetProcess)
            try
                if role of e is "AXTextArea" then
                    set value of e to messageText
                    return "set"
                end if
            end try
        end repeat
    end tell
    return "missing"
end run'''
    return osa(script, str(pid), message, timeout=30) == "set"


def send(pid: int) -> bool:
    try:
        key(pid, "return", command=True)
        return True
    except RuntimeError:
        return click_named(pid, ["送出", "Send"])


def wait_for_reply(pid: int, before: str, seconds: int = 90) -> tuple[bool, float]:
    started = time.monotonic()
    while time.monotonic() - started < seconds:
        try:
            after = static_text(pid)
            if len(after) > len(before) and after != before:
                return True, time.monotonic() - started
        except RuntimeError:
            pass
        time.sleep(1)
    return False, time.monotonic() - started


def capture(pid: int, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    # AXWindowNumber is suitable for screencapture; fall back to the primary screen.
    script = r'''on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        try
            return value of attribute "AXWindowNumber" of window 1 of targetProcess as text
        on error
            return ""
        end try
    end tell
end run'''
    window_id = ""
    try:
        window_id = osa(script, str(pid))
    except RuntimeError:
        pass
    command = ["screencapture", "-x"]
    if window_id.isdigit():
        command += ["-l", window_id]
    command.append(str(destination))
    subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def paste_file(pid: int, source: Path) -> bool:
    script = r'''on run argv
    set imagePath to item 1 of argv
    set the clipboard to (POSIX file imagePath)
end run'''
    try:
        osa(script, str(source))
        key(pid, "v", command=True)
        return True
    except (RuntimeError, FileNotFoundError):
        return False


def quit_app(pid: int) -> None:
    try:
        key(pid, "q", command=True)
        time.sleep(2)
    except Exception:
        pass
    subprocess.run(["kill", "-TERM", str(pid)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
