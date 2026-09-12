#!/usr/bin/env python3
"""T6 第二輪情境分組協作考 orchestrator（2026-07-03，EXAM_PROTOCOL 適用）

同一題、兩個陣容、M 模式正常額度（≤4 helpers、≤2 輪）：
  lineup-A（跨家族互補假設）: builder=gpt-5.4, reviewer=sonnet-5, sub=minimax-m3
  lineup-B（同家族對照）:     builder=gpt-5.5, reviewer=gpt-5.4,  sub=minimax-m3
流程: sub 需求候選 → builder 三檔 → reviewer findings → builder 修一輪 → seal(HMAC) → 評分。
主考官零引導；所有 relay 落盤；dispatch 記入 registry（Working 頁亮燈）。
"""
import hashlib, hmac, json, os, re, subprocess, sys, time, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN = os.path.join(REPO, ".tatwo-ultrawork", "協作考試", "20260703-collab-r2")
CLI = os.path.expanduser("~/.local/bin/tatwo-ultrawork")
GATEWAY = "http://127.0.0.1:4177/v1/responses"
SEAL_KEY = os.environ.get("TATWO_ARENA_SEAL_KEY", "").strip()
AUTH = json.load(open(os.path.expanduser("~/.codex/auth.json")))["tokens"]

TASK = """題目：離線「加密貨幣策略監控儀表板」單頁靜態站（全新題，非第一輪題目）。
需求：策略清單卡片（名稱/狀態/當日損益）、單一策略詳情面板、風險燈號區（DD/槓桿/連虧）、
暫停-恢復策略的模擬開關（純前端狀態）、深色專業風格、響應式。
硬規則：三檔 index.html / styles.css / app.js；離線可用無 CDN 無遠端資源；vanilla JS；
每檔 8000 字內完整閉合；最多 8 筆 sample data；不可真交易/真連線/憑證欄位。"""

LINEUPS = {
    "lineup-C": {"builder": "grok-build", "reviewer": "sonnet-5", "sub": "minimax-m3"},
    "lineup-D": {"builder": "minimax-m3", "reviewer": "grok-build", "sub": "minimax-m3"},
}
GPT_MODELS = {"gpt-5.4", "gpt-5.5", "chatgpt-pro-consult"}


def log(msg):
    print(msg, flush=True)


def sh(args):
    r = subprocess.run(args, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout


def dispatch(model, prompt, tag, lineup_dir, timeout_s=600, retries=2):
    body = {"model": model, "stream": model in GPT_MODELS, "store": False,
            "input": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(GATEWAY, data=json.dumps(body, ensure_ascii=False).encode(),
                                 headers={"Content-Type": "application/json"})
    if model in GPT_MODELS:
        req.add_header("Authorization", f"Bearer {AUTH['access_token']}")
        req.add_header("ChatGPT-Account-ID", AUTH["account_id"])
        req.add_header("OpenAI-Beta", "codex-1")
    last_err = ""
    for attempt in range(retries + 1):
        if attempt:
            time.sleep(10 * attempt)
        try:
            raw = urllib.request.urlopen(req, timeout=timeout_s).read().decode()
            text = ""
            if body["stream"]:
                for line in raw.splitlines():
                    if not line.startswith("data: "):
                        continue
                    try:
                        ev = json.loads(line[6:])
                    except Exception:
                        continue
                    if ev.get("type") == "response.output_text.delta":
                        text += ev.get("delta", "")
                    elif ev.get("type") == "response.completed" and not text:
                        for item in ev["response"].get("output", []):
                            for c in item.get("content", []):
                                if c.get("type") == "output_text":
                                    text += c.get("text", "")
            else:
                d = json.loads(raw)
                for item in d.get("output", []):
                    for c in item.get("content", []):
                        if c.get("type") in ("output_text", "text"):
                            text += c.get("text", "")
            if text.strip():
                os.makedirs(os.path.join(lineup_dir, "relay"), exist_ok=True)
                with open(os.path.join(lineup_dir, "relay", f"{tag}.md"), "w") as f:
                    f.write(f"# {tag} ({model})\n\nPROMPT:\n{prompt}\n\nOUTPUT:\n{text}")
                return text
            last_err = "empty output"
        except Exception as e:  # infra retry only
            last_err = str(e)[:200]
    raise RuntimeError(f"dispatch {tag} failed after retries: {last_err}")


def strip_fence(text):
    m = re.search(r"```[a-zA-Z]*\n(.*?)```", text, re.S)
    return (m.group(1) if m else text).strip()


def reg_dispatch(contract, binding, model, purpose):
    code, out = sh([CLI, "os", "dispatch", "begin", "--contract", contract,
                    "--binding", binding, "--model", model, "--subtask", purpose, "--json"])
    try:
        return json.loads(out)["data"]["id"]
    except Exception:
        return ""


def reg_update(contract, dispatch_id, status):
    if dispatch_id:
        sh([CLI, "os", "dispatch", "update", "--contract", contract,
            "--dispatch", dispatch_id, "--status", status, "--json"])


def seal_dir(project):
    hashes = {}
    for root, _, files in os.walk(project):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, project).replace(os.sep, "/")
            hashes[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    seal = {"schema": "TatwoArenaSubmissionSealV1", "sealed": True, "algorithm": "sha256",
            "fileHashes": hashes, "note": f"Sealed by collab orchestrator over {len(hashes)} files."}
    if SEAL_KEY:
        canonical = "\n".join(f"{k}:{hashes[k]}" for k in sorted(hashes))
        seal["signature"] = hmac.new(SEAL_KEY.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return seal


def grade(project):
    result = {"jsSyntaxOK": None, "webCheckErrors": None, "semanticHits": 0, "semanticGroups": 0}
    r = subprocess.run(["node", "--check", os.path.join(project, "app.js")],
                       capture_output=True, text=True)
    result["jsSyntaxOK"] = r.returncode == 0
    doctor = os.environ.get("TATWO_WEB_CHECK_BIN", "").strip()
    if not doctor:
        raise SystemExit(
            "error: TATWO_WEB_CHECK_BIN is required (path to tatwo-frontend-doctor); "
            "no private absolute-path default"
        )
    r = subprocess.run([doctor, project, "--json", "--json-compact", "--blocking", "none"],
                       capture_output=True, text=True, timeout=120, cwd=os.path.dirname(doctor))
    try:
        w = json.loads(r.stdout)
        diags = [d for d in w.get("diagnostics", [])
                 if not (str(d.get("ruleId", "")).startswith(("react-", "react-hooks", "state-effects/"))
                         or re.search(r"jsx", str(d.get("ruleId", "")), re.I)
                         or re.search(r"\bJSX\b|\bReact\b", str(d.get("message", ""))))]
        result["webCheckErrors"] = sum(1 for d in diags if d.get("severity") == "error")
        result["webCheckWarnings"] = sum(1 for d in diags if d.get("severity") == "warning")
    except Exception as e:
        result["webCheckErrors"] = -1
        result["webCheckParseError"] = str(e)[:120]
    text = ""
    for fn in ("index.html", "styles.css", "app.js"):
        p = os.path.join(project, fn)
        if os.path.exists(p):
            text += open(p, encoding="utf-8", errors="ignore").read().lower()
    groups = [["策略", "strategy"], ["損益", "pnl", "profit"], ["風險", "risk"], ["燈號", "signal", "indicator"],
              ["暫停", "pause"], ["恢復", "resume"], ["槓桿", "leverage"], ["回撤", "drawdown", "dd"],
              ["詳情", "detail"], ["@media", "responsive"]]
    result["semanticGroups"] = len(groups)
    result["semanticHits"] = sum(1 for g in groups if any(k in text for k in g))
    return result


def run_lineup(name, roles):
    log(f"STAGE {name} start builder={roles['builder']} reviewer={roles['reviewer']} sub={roles['sub']}")
    ldir = os.path.join(RUN, name)
    project = os.path.join(ldir, "generated-project")
    os.makedirs(project, exist_ok=True)
    code, out = sh([CLI, "os", "begin", "--mode", "M", "--scenario", "coding",
                    "--objective", f"第二輪協作考 {name}", "--json"])
    contract = json.loads(out)["data"]["contractID"]
    log(f"STAGE {name} contract {contract}")

    d1 = reg_dispatch(contract, "binding-sub", roles["sub"], "需求候選")
    reg_update(contract, d1, "running")
    checklist = dispatch(roles["sub"],
        f"{TASK}\n\n你是 sub。列出 10 條「builder 容易漏掉的需求細節與邊界案例」清單，每條一行，不寫程式。",
        "sub-checklist", ldir)
    reg_update(contract, d1, "completed")
    log(f"STAGE {name} sub checklist done ({len(checklist)} chars)")

    d2 = reg_dispatch(contract, "binding-lead", roles["builder"], "初版三檔")
    reg_update(contract, d2, "running")
    for fn, extra in (("index.html", "必須引用 styles.css 與 app.js，5-8 個 section"),
                      ("styles.css", "深色專業風、grid/flex、focus states、@media"),
                      ("app.js", "vanilla JS、通過 node --check、模擬開關與詳情互動")):
        content = dispatch(roles["builder"],
            f"{TASK}\n\nsub 的需求候選清單（自行取捨）：\n{checklist}\n\n只輸出 {fn} 完整原始內容，"
            f"不要 fence 不要解釋。{extra}。8000 字內完整閉合。",
            f"builder-{fn}", ldir)
        open(os.path.join(project, fn), "w").write(strip_fence(content))
        log(f"STAGE {name} builder {fn} written")
    reg_update(contract, d2, "completed")

    d3 = reg_dispatch(contract, "binding-supervisor", roles["reviewer"], "審查 findings")
    reg_update(contract, d3, "running")
    src = "".join(f"\n=== {fn} ===\n{open(os.path.join(project, fn)).read()[:7000]}"
                  for fn in ("index.html", "styles.css", "app.js"))
    findings = dispatch(roles["reviewer"],
        f"{TASK}\n\n你是審查者。審查以下三檔，列出最多 6 條 must-fix（含檔名與原因，"
        f"特別注意 HTML 語意巢狀、未閉合結構、可運作性），只列問題不寫完整程式：\n{src}",
        "reviewer-findings", ldir)
    reg_update(contract, d3, "completed")
    log(f"STAGE {name} reviewer findings done")

    d4 = reg_dispatch(contract, "binding-lead", roles["builder"], "修訂輪")
    reg_update(contract, d4, "running")
    for fn in ("index.html", "styles.css", "app.js"):
        content = dispatch(roles["builder"],
            f"{TASK}\n\n審查者 must-fix 清單：\n{findings}\n\n這是你上一版 {fn}：\n"
            f"{open(os.path.join(project, fn)).read()[:7500]}\n\n"
            f"輸出修正後的完整 {fn}，只輸出檔案內容不要 fence。8000 字內完整閉合。",
            f"builder-rev-{fn}", ldir)
        open(os.path.join(project, fn), "w").write(strip_fence(content))
    reg_update(contract, d4, "completed")
    log(f"STAGE {name} revision done, sealing")

    os.makedirs(os.path.join(ldir, "final-submission"), exist_ok=True)
    json.dump(seal_dir(project), open(os.path.join(ldir, "final-submission", "seal.json"), "w"),
              ensure_ascii=False, indent=1)
    g = grade(project)
    json.dump({"lineup": name, "roles": roles, "contract": contract, "grade": g},
              open(os.path.join(ldir, "grade.json"), "w"), ensure_ascii=False, indent=1)
    log(f"STAGE {name} GRADE {json.dumps(g, ensure_ascii=False)}")
    return g


def main():
    os.makedirs(RUN, exist_ok=True)
    results = {}
    for name, roles in LINEUPS.items():
        try:
            results[name] = run_lineup(name, roles)
        except Exception as e:
            results[name] = {"error": str(e)[:300]}
            log(f"STAGE {name} FAILED {str(e)[:200]}")
    json.dump(results, open(os.path.join(RUN, "results.json"), "w"), ensure_ascii=False, indent=1)
    log("STAGE ALL_DONE " + json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
