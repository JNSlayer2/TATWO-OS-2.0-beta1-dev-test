#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 package-release.sh 的 dist 產物整理成 install.sh 的 TATWO_OS_OFFLINE_RELEASE 目錄。
用法：make-offline-release.py <dist/release-vX.Y.Z.NNN> <輸出目錄> [repo]
產出：repository、release.json（GitHub 格式：tag_name、assets[].name/browser_download_url/size）、各附件 hardlink/copy。
未發布前用於本機安裝驗收；install.sh 仍會驗 sha256、版本綁定、簽章。"""
import json, os, shutil, sys

dist, out = sys.argv[1], sys.argv[2]
repo = sys.argv[3] if len(sys.argv) > 3 else "tatwo214/TATWO-OS-2.0-private"
version = os.path.basename(dist.rstrip("/")).replace("release-", "")
assert version.startswith("v"), version
os.makedirs(out, exist_ok=True)
assets = []
for name in sorted(os.listdir(dist)):
    if not name.startswith("TATWO-OS"): continue
    src = os.path.join(dist, name)
    if not os.path.isfile(src): continue
    dst = os.path.join(out, name)
    # 一律以 dist 為準覆蓋（舊候選殘留會讓安裝裝到舊 runtime；2026-09-18 踩過）
    if os.path.abspath(src) == os.path.abspath(dst): pass  # 就地產生 release.json（dist 即輸出目錄），不動檔案
    elif os.path.exists(dst): os.remove(dst)
    if os.path.abspath(src) != os.path.abspath(dst):
        try: os.link(src, dst)
        except OSError: shutil.copy2(src, dst)
    assets.append({"name": name, "size": os.path.getsize(src),
                   "browser_download_url": f"https://github.com/{repo}/releases/download/{version}/{name}"})
with open(os.path.join(out, "repository"), "w") as f: f.write(repo + "\n")
with open(os.path.join(out, "release.json"), "w") as f:
    json.dump({"tag_name": version, "name": version, "draft": False, "prerelease": False, "assets": assets}, f, indent=2)
print(f"{version}: {len(assets)} assets → {out}")
for a in assets: print(f"  {a['size']:>12} {a['name']}")
