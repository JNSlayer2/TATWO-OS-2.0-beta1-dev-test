#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""安裝候選版後的功能檢查（單機部分）。在每台設備本機執行；只讀，不寫入任何 OS 資料。
用法：python3 functional-check.py <期望版本 例如 2.0.8.001> <期望角色 primary|secondary> <主設備 os.md sha256 前12碼>
輸出每項 PASS/FAIL，最後 SUMMARY。"""
import hashlib, json, os, socket, subprocess, sys, uuid

VERSION, ROLE, PRIMARY_OS_HASH = sys.argv[1], sys.argv[2], sys.argv[3]
HOME = os.path.expanduser("~")
ENTRY = os.environ.get("TATWO_ENTRY") or os.path.join(HOME, "AI", "TATWO OS")
AS = os.path.join(HOME, "Library", "Application Support", "tatwo2")
results = []

def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'} {name}{(' — ' + detail) if detail else ''}")

def sha12(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]

def rpc(method, params=None):
    sock = os.path.join(AS, "live", "os.sock")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(20)
    s.connect(sock)
    req = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params or {}}
    s.sendall((json.dumps(req) + "\n").encode())
    s.shutdown(socket.SHUT_WR)  # bridge 用 readToEnd()，要半關閉才會回應
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
    s.close()
    return json.loads(buf.decode())

# 1. 入口結構
for name in ["os.md", "skillet.md", "device.json"]:
    check(f"entry file {name}", os.path.isfile(os.path.join(ENTRY, name)))
for name in ["tatwo2", "gbrain", "rooms", "staging", "archive"]:
    check(f"entry dir {name}", os.path.isdir(os.path.join(ENTRY, name)))

# 2. 憲法雜湊
try:
    h = sha12(os.path.join(ENTRY, "os.md"))
    check("constitution hash equals primary", h == PRIMARY_OS_HASH, h)
except Exception as e:
    check("constitution hash equals primary", False, str(e))

# 3. 本機身份
try:
    ident = json.load(open(os.path.join(ENTRY, "device.json")))
    check("device.json role", ident.get("role") == ROLE, ident.get("role"))
    check("device.json epoch present", isinstance(ident.get("epoch"), int) and ident["epoch"] >= 1, str(ident.get("epoch")))
    check("device.json primaryDeviceID present", bool(ident.get("primaryDeviceID")))
except Exception as e:
    check("device.json readable", False, str(e))

# 4. App 版本
try:
    v = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                                 "/Applications/TATWO OS.app/Contents/Info.plist"]).decode().strip()
    check("installed App version", v == VERSION, v)
    sig = subprocess.run(["codesign", "--verify", "--deep", "--strict", "/Applications/TATWO OS.app"], capture_output=True)
    check("installed App signature valid", sig.returncode == 0, sig.stderr.decode()[:120])
    helper = "/Applications/TATWO OS.app/Contents/Helpers/gbrain"
    check("GBrain helper bundled", os.path.isfile(helper))
except Exception as e:
    check("installed App version", False, str(e))

# 5. 執行期上游由憲法產生
try:
    up = open(os.path.join(AS, "os", "os-upstream.md"), encoding="utf-8").read()
    check("runtime upstream has 鐵律 9/10 equivalents", ("發行" in up and "授權跟隨" in up) or ("9." in up and "10." in up))
    check("runtime upstream carries source constitution hash", PRIMARY_OS_HASH in up or "sha256" in up.lower())
    check("runtime upstream names this device role", ("主設備" in up) or ("副設備" in up))
except Exception as e:
    check("runtime upstream readable", False, str(e))

# 6. device_status RPC（App 必須開著）；回應格式 {"id","ok","result"}，欄位為 DeviceStatusSnapshot
try:
    r = rpc("device_status")
    res = r.get("result") or {}
    check("device_status RPC responds ok", r.get("ok") is True, json.dumps(r)[:160])
    ident = (res.get("identity") or {}).get("value") or {}
    check("device_status role matches", ident.get("role") == ROLE, str(ident.get("role")))
    check("device_status epoch >= 1", isinstance(ident.get("epoch"), int) and ident["epoch"] >= 1, str(ident.get("epoch")))
    app_v = (res.get("appVersion") or {}).get("value")
    check("device_status appVersion matches", str(app_v).split(" ")[0] == VERSION, str(app_v))
    c_sha = ((res.get("constitution") or {}).get("value") or {}).get("sha256") or ""
    check("device_status constitution sha matches primary", c_sha.startswith(PRIMARY_OS_HASH), c_sha[:12] or (res.get("constitution") or {}).get("reason"))
    rules = (res.get("rules") or {}).get("value") or {}
    # 真值：aligned（已對齊）／user_kept（使用者保留自訂）／pending（待套用）／unknown；只有 aligned 算綠
    check("device_status rules state aligned", rules.get("state") == "aligned", str(rules.get("state")))
    gen = rules.get("generatedFromConstitutionHash") or ""
    check("device_status rules generated from current constitution", gen.startswith(PRIMARY_OS_HASH), gen[:12])
    gb = (res.get("gbrain") or {})
    check("device_status gbrain configured", gb.get("value") not in (None, "not_configured"), json.dumps(gb)[:120])
except Exception as e:
    check("device_status RPC responds ok", False, str(e))

# 7. 金鑰不落檔（掃入口 gbrain 目錄）
leak = False
for root, _, files in os.walk(os.path.join(ENTRY, "gbrain")):
    for f in files:
        try:
            data = open(os.path.join(root, f), "rb").read()
            if b"sk-" in data and (b"OPENAI" in data or b"sk-proj" in data or b"sk-ant" in data):
                leak = True
        except Exception:
            pass
check("no API key material under entry gbrain/", not leak)

ok = sum(1 for _, x in results if x); total = len(results)
print(f"SUMMARY {ok}/{total} pass, {total-ok} fail")
sys.exit(0 if ok == total else 1)
