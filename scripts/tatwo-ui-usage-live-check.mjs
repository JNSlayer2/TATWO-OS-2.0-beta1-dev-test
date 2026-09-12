#!/usr/bin/env node
import {
  extractSwiftFunctionBody,
  extractSwiftTypeBody,
  readRequiredSources,
  requireSourceMarker,
} from "./tatwo-static-audit-source-contract.mjs";

const root = process.cwd();
const manifest = [
  { id: "usage", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/TatwoM3PrototypeViews.swift" },
  { id: "header", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/HeaderQuotaStrip.swift" },
  { id: "shell", relativePath: "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift" },
  { id: "package", relativePath: "Package.swift" },
  { id: "store", relativePath: "Packages/AISwitchProviders/Sources/AISwitchProviders/CodexV3ImportStore.swift" },
  { id: "buildRun", relativePath: "script/build_and_run.sh" },
];

const contractMigrations = [
  {
    id: "codex.primary.reset",
    classification: "stale-contract",
    legacyContract: 'quotaWindowMetricRow(left: "5小時", ...)',
    currentEquivalent: 'QuotaWindowBar(title: "5小時", ...)',
    justification: "The current reusable bar owns percent expiry and reset-deadline presentation.",
  },
  {
    id: "codex.secondary.reset",
    classification: "stale-contract",
    legacyContract: 'quotaWindowMetricRow(left: "1週", ...)',
    currentEquivalent: 'QuotaWindowBar(title: "1週", ...)',
    justification: "The weekly window moved to the same typed current component without weakening the two-window semantics.",
  },
  {
    id: "codex.window_rows_guarded",
    classification: "stale-contract",
    legacyContract: 'if row.id == "codex-gpt"',
    currentEquivalent: "QuotaProviderDetail row.hasLiveUsage plus typed LiveQuotaDisplay fields",
    justification: "Provider detail now renders live windows from typed availability instead of array ordering or one provider-ID branch.",
  },
  {
    id: "codex.window_expired_refreshing",
    classification: "stale-contract",
    legacyContract: 'value: expired ? "刷新中" : percentText(percent)',
    currentEquivalent: "QuotaWindowBar passes nil percent after expiry and LiveQuotaDisplay returns 刷新中",
    justification: "Expired values are hidden in both detailed and compact presentation using current typed state.",
  },
  {
    id: "codex.reset_credits.available",
    classification: "stale-contract",
    legacyContract: 'quotaMetricRow(left: "Codex重置額度", ...)',
    currentEquivalent: "QuotaProviderDetail reset-credit HStack and resetCreditExpiryText",
    justification: "Reset credits remain separate from the weekly window while using the current compact layout.",
  },
  {
    id: "quota.on_appear_stale_refresh",
    classification: "stale-contract",
    legacyContract: "one exact multiline .onAppear presentation",
    currentEquivalent: "ModelQuotaTopDeck .task + .onAppear and TatwoHeaderQuotaStrip .task",
    justification: "Both full Usage and header authority refresh stale data on presentation, with 60-second live timers.",
  },
  {
    id: "quota.authority_split",
    classification: "stale-contract",
    legacyContract: "all usage markers in TatwoM3PrototypeViews plus monolith App file",
    currentEquivalent: "TatwoM3PrototypeViews + HeaderQuotaStrip, with export live path in AppShell",
    justification: "Visible usage authority is split between the full page and header strip while export remains explicitly routed through AppShell.",
  },
];

const scopes = new Map();
const checks = [];
const findings = [];
let sourceSnapshot = { algorithm: "sha256", files: [] };

function check(id, sourcePath, symbol, markers, expected) {
  const body = scopes.get(`${sourcePath}#${symbol}`);
  const missing = [];
  for (const marker of markers) {
    try {
      requireSourceMarker(body, marker, { sourcePath, symbol });
      if (!body.includes(marker)) throw new Error("exact marker missing");
    } catch {
      missing.push(marker);
    }
  }
  const ok = missing.length === 0;
  checks.push({ id, ok, sourcePath, symbol, expected, missing });
  if (!ok) {
    findings.push({
      id,
      classification: "candidate-regression",
      sourcePath,
      symbol,
      missing,
      expected,
    });
  }
}

function checkFile(id, sourcePath, symbol, source, markers, expected) {
  const active = stripCommentsPreservingStrings(source);
  const missing = markers.filter(marker => !active.includes(marker));
  const ok = missing.length === 0;
  checks.push({ id, ok, sourcePath, symbol, expected, missing });
  if (!ok) {
    findings.push({
      id,
      classification: "candidate-regression",
      sourcePath,
      symbol,
      missing,
      expected,
    });
  }
}

function checkPredicate(id, sourcePath, symbol, ok, evidence, expected) {
  checks.push({ id, ok, sourcePath, symbol, expected, evidence });
  if (!ok) {
    findings.push({
      id,
      classification: "candidate-regression",
      sourcePath,
      symbol,
      evidence,
      expected,
    });
  }
}

try {
  const loaded = readRequiredSources({ root, manifest });
  sourceSnapshot = loaded.sourceSnapshot;
  const specs = [
    ["usage", "struct", "ModelQuotaTopDeck"],
    ["usage", "struct", "QuotaProviderDetail"],
    ["usage", "struct", "QuotaWindowBar"],
    ["usage", "struct", "LiveQuotaDeckSnapshot"],
    ["usage", "struct", "LiveQuotaDisplay"],
    ["usage", "enum", "TatwoLiveQuotaReader"],
    ["header", "struct", "HeaderQuotaStripModel"],
    ["header", "struct", "TatwoHeaderQuotaStrip"],
    ["header", "struct", "HeaderQuotaPopover"],
    ["shell", "enum", "TatwoPanelSnapshotExporter"],
    ["store", "struct", "CodexV3ImportStore"],
    ["store", "struct", "CodexResetCreditsAPIResponse"],
    ["store", "struct", "CodexResetCredit"],
  ];
  for (const [sourceID, kind, symbol] of specs) {
    const source = loaded.sources.get(sourceID);
    try {
      scopes.set(
        `${source.path}#${symbol}`,
        extractSwiftTypeBody(source.text, { kind, name: symbol, stripComments: true }),
      );
    } catch (error) {
      findings.push({
        id: "source.symbol",
        classification: "source-contract",
        sourcePath: source.path,
        symbol,
        error: error.message,
      });
    }
  }

  const paths = Object.fromEntries([...loaded.sources].map(([id, source]) => [id, source.path]));
  try {
    const clientBody = extractCodexUsageClientBody(loaded.sources.get("store").text);
    scopes.set(
      `${paths.store}#CodexUsageClient.queryUsage`,
      extractSwiftFunctionBody(clientBody, { name: "queryUsage", stripComments: true }),
    );
  } catch (error) {
    findings.push({
      id: "source.symbol",
      classification: "source-contract",
      sourcePath: paths.store,
      symbol: "CodexUsageClient.queryUsage",
      error: error.message,
    });
  }

  checkFile(
    "usage.import_authority",
    paths.usage,
    "TatwoM3PrototypeViews.swift",
    loaded.sources.get("usage").text,
    ["import AISwitchProviders"],
    "Usage UI must link the live Codex provider implementation.",
  );
  check(
    "usage.full_page_refresh",
    paths.usage,
    "ModelQuotaTopDeck",
    [
      "Timer.publish(every: 60",
      "init(providers: [UsageProviderStatus], initialLiveSnapshot: LiveQuotaDeckSnapshot? = nil)",
      "refreshLiveUsageIfStale(maxAge: 10)",
      "liveSnapshot.isStale(maxAge: maxAge)",
      "TatwoLiveQuotaReader.load(",
    ],
    "Full Usage authority must initialize live evidence, refresh stale data, and auto-refresh every 60 seconds.",
  );
  check(
    "usage.current_windows_and_credits",
    paths.usage,
    "QuotaProviderDetail",
    [
      'QuotaWindowBar(title: "5小時"',
      'QuotaWindowBar(title: "1週"',
      'Label(row.resetCreditsAvailable.map { "重置 \\($0) 次" } ?? "重置次數未回傳"',
      "resetCreditExpiryText(row.resetCreditExpiryDates, fallback: row.resetCreditsExpiresAt)",
    ],
    "Current Usage presentation must retain separate 5-hour, 1-week, reset-credit, and expiry semantics.",
  );
  check(
    "usage.expired_window_policy",
    paths.usage,
    "QuotaWindowBar",
    [
      "Text(percentText(expired ? nil : percent))",
      "Text(expired ? expiredResetText(resetAt) : resetText(resetAt))",
      "if let livePercent = expired ? nil : percent",
      "resetAt.map { $0 <= Date() }",
    ],
    "Expired detailed windows must hide stale percentages and show an expired/reset deadline.",
  );
  check(
    "usage.snapshot_staleness",
    paths.usage,
    "LiveQuotaDeckSnapshot",
    ["func isStale(maxAge: TimeInterval", "now.timeIntervalSince(loadedAt) > maxAge"],
    "Live quota snapshots must expose an explicit freshness policy.",
  );
  check(
    "usage.compact_expiry_policy",
    paths.usage,
    "LiveQuotaDisplay",
    [
      "var displayRemainingPercent: Int?",
      "codexWindowExpired ? nil : remainingPercent",
      'codexWindowExpired ? "刷新中" : statusText',
      'guard id == "codex-gpt"',
    ],
    "Compact presentation must hide expired Codex values and report refreshing.",
  );
  check(
    "usage.live_reader",
    paths.usage,
    "TatwoLiveQuotaReader",
    [
      "CodexV3ImportStore().loadLiveSnapshot(resolveActiveEmail: true)",
      "account.rateLimitResetCreditsAvailableCount",
      "account.rateLimitResetCreditsExpiresAt",
      "account.rateLimitResetCreditsExpiryEpochs",
      "private static func loadClaude(",
      "auth.subscriptionType",
      '["max", "pro", "team", "enterprise"]',
      'permissionLabel: auth.timedOut ? "未判定 · 不顯示用量" : "不顯示假用量"',
      'permissionLabel: "\\(auth.maskedEmail) · \\(planLabel) · 非用量"',
      'caption: reviewerReady ? "\\(planLabel)；無 live 用量；Opus 副審授權OK"',
    ],
    "Live reader must preserve Codex backend data and Claude auth-only/no-fake-quota semantics.",
  );
  const readerBody = scopes.get(`${paths.usage}#TatwoLiveQuotaReader`) ?? "";
  const claudeStart = readerBody.indexOf("private static func loadClaude");
  const claudeEnd = readerBody.indexOf("private static func dateFromEpoch", claudeStart);
  const claudeBody = claudeStart >= 0 && claudeEnd > claudeStart
    ? readerBody.slice(claudeStart, claudeEnd)
    : "";
  const nilCounts = {
    remainingPercent: (claudeBody.match(/remainingPercent:\s*nil/g) ?? []).length,
    primaryRemainingPercent: (claudeBody.match(/primaryRemainingPercent:\s*nil/g) ?? []).length,
    secondaryRemainingPercent: (claudeBody.match(/secondaryRemainingPercent:\s*nil/g) ?? []).length,
  };
  checkPredicate(
    "usage.claude_always_nil_percent",
    paths.usage,
    "TatwoLiveQuotaReader.loadClaude",
    Object.values(nilCounts).every(count => count >= 2),
    nilCounts,
    "Both logged-out and logged-in Claude branches must keep all quota percentages nil.",
  );
  check(
    "usage.header_state",
    paths.header,
    "HeaderQuotaStripModel",
    [
      "static let staleAfter: TimeInterval = 300",
      "state = .stale",
      "state = percent <= 15 ? .critical : .live",
      "alert = .red",
      "alert = .amber",
    ],
    "Header authority must distinguish stale, live, critical, amber, and red states.",
  );
  check(
    "usage.header_live_path",
    paths.header,
    "TatwoHeaderQuotaStrip",
    [
      "Timer.publish(every: 60",
      "refreshIfStale(maxAge: 10)",
      "TatwoLiveQuotaReader.load(",
      "HeaderQuotaPopover(",
      "openUsage()",
    ],
    "Header strip must refresh live data, expose a popover, and route to full Usage.",
  );
  check(
    "usage.header_popover",
    paths.header,
    "HeaderQuotaPopover",
    ["ForEach(model.segments)", "segment.remainingPercent", "segment.resetAt", 'Button("完整 Usage"'],
    "Header popover must disclose per-provider remaining values/reset times and open full Usage.",
  );
  check(
    "usage.export_live_path",
    paths.shell,
    "TatwoPanelSnapshotExporter",
    [
      'env["TATWO_ULTRAWORK_EXPORT_LIVE_USAGE"] == "1"',
      "TatwoLiveQuotaReader.load(providers: appSnapshot.catalog.usageProviders)",
      "semaphore.wait(timeout: .now() + 8.0)",
    ],
    "Snapshot export must use the same live reader and an explicit bounded wait.",
  );
  checkFile(
    "usage.package_dependency",
    paths.package,
    "Package.swift",
    loaded.sources.get("package").text,
    ['name: "TatwoUltraworkMac"', 'dependencies: ["TatwoUltraworkCore", "AISwitchCore", "AISwitchProviders"]'],
    "TatwoUltraworkMac must link AISwitchProviders.",
  );
  check(
    "usage.store_active_auth",
    paths.store,
    "CodexV3ImportStore",
    [
      "liveUsageByEmail(for: registry.accounts, activeEmail: activeEmail)",
      "let authURL = liveAuthURL(for: account, activeEmail: activeEmail)",
      'codexHomeURL.appendingPathComponent("auth.json")',
      "Data(contentsOf: authURL)",
    ],
    "Codex usage must prefer active App/CLI auth through a read-only data path.",
  );
  check(
    "usage.store_reset_credit_decode",
    paths.store,
    "CodexResetCreditsAPIResponse",
    [
      "availableExpiryEpochs",
      'status == "available"',
      'resetType == "codex_rate_limits"',
      "availableCodexResetCreditCount",
    ],
    "Reset-credit response must preserve available count and all available expiries.",
  );
  check(
    "usage.store_reset_credit_expiry",
    paths.store,
    "CodexResetCredit",
    ['case expiresAt = "expires_at"', "ISO8601DateFormatter()", "expiresAtEpoch"],
    "Reset-credit expiry must decode the endpoint expires_at field.",
  );
  check(
    "usage.store_reset_credit_endpoint",
    paths.store,
    "CodexUsageClient.queryUsage",
    ['URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")'],
    "Codex live usage must query the dedicated reset-credit endpoint.",
  );
  checkFile(
    "usage.smoke_contract",
    paths.buildRun,
    "build_and_run.sh",
    loaded.sources.get("buildRun").text,
    [
      "TATWO_ULTRAWORK_EXPORT_LIVE_USAGE=1",
      "tatwo-live-quota-runtime-check.mjs",
      "live-quota-runtime.json",
      "tatwo-live-quota-negative-check.mjs",
      '[[ "$pixel_width" == "520" && "$pixel_height" == "620" ]]',
    ],
    "UI smoke must verify live usage, sanitized runtime evidence, negative auth behavior, and 520x620 panel dimensions.",
  );

  const activeUsage = stripCommentsPreservingStrings(loaded.sources.get("usage").text);
  const forbidden = [
    [/\bquotaPercent\s*\(/, "legacy fake quotaPercent helper"],
    [/\bshortWindowPercent\s*\(/, "legacy fake short-window helper"],
    [/\bweekPercent\s*\(/, "legacy fake week helper"],
    [/[0-9]{1,2}月[0-9]{1,2}日/, "hard-coded reset date"],
    [/remainingPercent:\s*(?:[1-9][0-9]?|100)\b/, "hard-coded remaining percentage"],
    [/live 未驗證|sourceBadge:\s*"未驗證"/, "ambiguous unverified live copy"],
  ];
  for (const [pattern, label] of forbidden) {
    checkPredicate(
      `usage.forbidden.${label.replaceAll(" ", "_")}`,
      paths.usage,
      "TatwoM3PrototypeViews.swift",
      !pattern.test(activeUsage),
      label,
      `${label} must not reappear in active Usage code.`,
    );
  }
} catch (error) {
  findings.push({
    id: "source.manifest",
    classification: "source-contract",
    sourcePath: "required-source-manifest",
    symbol: "manifest",
    error: error.message,
  });
}

const result = {
  schema: "TatwoUIUsageLiveCheckV2",
  ok: findings.length === 0,
  sourceSnapshot,
  contractMigrations,
  summary: {
    total: checks.length,
    passed: checks.filter(item => item.ok).length,
    failed: findings.length,
  },
  checks,
  findings,
};

console.log(JSON.stringify(result, null, 2));
process.exit(result.ok ? 0 : 1);

function stripCommentsPreservingStrings(source) {
  const output = [...source];
  let index = 0;
  let blockDepth = 0;
  let quote = null;
  while (index < source.length) {
    if (quote) {
      if (source[index] === "\\" && quote === '"') {
        index += 2;
        continue;
      }
      if (source.startsWith(quote, index)) {
        index += quote.length;
        quote = null;
        continue;
      }
      index += 1;
      continue;
    }
    if (source.startsWith('"""', index)) {
      quote = '"""';
      index += 3;
      continue;
    }
    if (source[index] === '"') {
      quote = '"';
      index += 1;
      continue;
    }
    if (source.startsWith("//", index)) {
      while (index < source.length && source[index] !== "\n") output[index++] = " ";
      continue;
    }
    if (source.startsWith("/*", index)) {
      blockDepth = 1;
      output[index++] = " ";
      output[index++] = " ";
      while (index < source.length && blockDepth > 0) {
        if (source.startsWith("/*", index)) {
          blockDepth += 1;
          output[index++] = " ";
          output[index++] = " ";
        } else if (source.startsWith("*/", index)) {
          blockDepth -= 1;
          output[index++] = " ";
          output[index++] = " ";
        } else {
          if (source[index] !== "\n") output[index] = " ";
          index += 1;
        }
      }
      continue;
    }
    index += 1;
  }
  return output.join("");
}

function extractCodexUsageClientBody(source) {
  const rewritten = source.replace(
    /\bclass\s+CodexUsageClient\b/g,
    "struct CodexUsageClient",
  );
  return extractSwiftTypeBody(rewritten, {
    kind: "struct",
    name: "CodexUsageClient",
    stripComments: true,
  });
}
