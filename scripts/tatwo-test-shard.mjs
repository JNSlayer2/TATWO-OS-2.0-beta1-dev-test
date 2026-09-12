#!/usr/bin/env node

/**
 * Deterministic test-suite sharder.
 *
 * This is a pure planning utility: it emits filter arguments only.  It never
 * starts a test runner, dispatches a remote job, or writes a workspace.
 *
 * Usage:
 *   node scripts/tatwo-test-shard.mjs \
 *     --suites-file suites.txt --shards 3 --index 1
 *   node scripts/tatwo-test-shard.mjs \
 *     --from-log swift-test.log --shards 3 --index 1
 *   node scripts/tatwo-test-shard.mjs \
 *     --from-log swift-test.log --shards 3 --index 1 --verify-partition
 *   node scripts/tatwo-test-shard.mjs --selftest
 *
 * stdout contains one `--filter=<suite>` argument per selected leaf suite. An
 * empty shard (valid when N > suite count) emits no lines and exits 0.
 * Aggregate labels are excluded and noted on stderr. `--verify-partition`
 * proves the union of all shards equals the leaf universe with no duplicates.
 */

import fs from "node:fs";
import process from "node:process";

const SCHEMA = "TatwoTestShardSelftestV1";

function usage() {
  return [
    "Usage:",
    "  node scripts/tatwo-test-shard.mjs --suites-file <file> --shards N --index i",
    "  node scripts/tatwo-test-shard.mjs --from-log <file> --shards N --index i [--verify-partition]",
    "  node scripts/tatwo-test-shard.mjs --selftest",
    "",
    "Input:",
    "  --suites-file  one suite name per non-empty line",
    "  --from-log     parse Test Suite started/passed/failed lines (leading",
    "                 whitespace accepted); aggregates are excluded",
    "  --shards N     positive shard count",
    "  --index i      zero-based shard index (0 <= i < N)",
    "",
    "Output:",
    "  one --filter=<suite> argument per line; no execution or dispatch occurs",
  ].join("\n");
}

function fail(message) {
  throw new Error(message);
}

function parsePositiveInteger(raw, label) {
  if (!/^[0-9]+$/.test(String(raw))) {
    fail(`${label} must be a positive integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) {
    fail(`${label} must be a positive integer`);
  }
  return value;
}

function parseNonNegativeInteger(raw, label) {
  if (!/^[0-9]+$/.test(String(raw))) {
    fail(`${label} must be a non-negative integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(`${label} must be a non-negative integer`);
  }
  return value;
}

function parseArgs(argv) {
  const options = {
    suitesFile: null,
    fromLog: null,
    shards: null,
    index: null,
    verifyPartition: false,
    selftest: false,
  };

  for (let cursor = 0; cursor < argv.length; cursor += 1) {
    const arg = argv[cursor];
    if (arg === "--help" || arg === "-h") {
      return { help: true };
    }
    if (arg === "--selftest") {
      options.selftest = true;
      continue;
    }
    if (arg === "--verify-partition") {
      options.verifyPartition = true;
      continue;
    }
    const nextValue = (label) => {
      if (cursor + 1 >= argv.length) fail(`${label} requires a value`);
      cursor += 1;
      return argv[cursor];
    };
    if (arg === "--suites-file") {
      options.suitesFile = nextValue(arg);
      continue;
    }
    if (arg === "--from-log") {
      options.fromLog = nextValue(arg);
      continue;
    }
    if (arg === "--shards") {
      options.shards = nextValue(arg);
      continue;
    }
    if (arg === "--index") {
      options.index = nextValue(arg);
      continue;
    }
    const equals = arg.indexOf("=");
    if (equals > 0) {
      const key = arg.slice(0, equals);
      const value = arg.slice(equals + 1);
      if (!value) fail(`${key} requires a value`);
      if (key === "--suites-file") options.suitesFile = value;
      else if (key === "--from-log") options.fromLog = value;
      else if (key === "--shards") options.shards = value;
      else if (key === "--index") options.index = value;
      else fail(`unknown argument: ${arg}`);
      continue;
    }
    fail(`unknown argument: ${arg}`);
  }

  if (options.selftest) {
    if (argv.length !== 1 || argv[0] !== "--selftest") {
      fail("--selftest cannot be combined with other arguments");
    }
    return options;
  }

  if (Boolean(options.suitesFile) === Boolean(options.fromLog)) {
    fail("provide exactly one of --suites-file or --from-log");
  }
  if (options.shards === null) fail("--shards is required");
  if (options.index === null) fail("--index is required");
  options.shards = parsePositiveInteger(options.shards, "--shards");
  options.index = parseNonNegativeInteger(options.index, "--index");
  if (options.index >= options.shards) {
    fail("--index must be less than --shards");
  }
  return options;
}

function stripSuiteQuotes(value) {
  const trimmed = value.trim();
  if (
    trimmed.length >= 2 &&
    ((trimmed.startsWith("'") && trimmed.endsWith("'")) ||
      (trimmed.startsWith('"') && trimmed.endsWith('"')))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function requireSuiteName(value, source) {
  const name = stripSuiteQuotes(value);
  if (!name) fail(`${source} contains an empty suite name`);
  if (name.includes("\n") || name.includes("\r")) {
    fail(`${source} contains a suite name with a newline`);
  }
  return name;
}

function isAggregateSuite(name) {
  return name === "All tests" || name.endsWith(".xctest");
}

function uniqueRecords(records, source) {
  if (records.length === 0) fail(`${source} contains no test suites`);
  const seen = new Set();
  for (const record of records) {
    if (seen.has(record.name)) {
      fail(`${source} contains duplicate suite: ${record.name}`);
    }
    seen.add(record.name);
  }
  return records;
}

function readSuitesFile(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    fail(`cannot read suites file ${filePath}: ${error.message}`);
  }
  const aggregateLabels = [];
  const records = text
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .flatMap((line) => {
      const name = requireSuiteName(line, `suites file ${filePath}`);
      if (isAggregateSuite(name)) {
        aggregateLabels.push(name);
        return [];
      }
      return [{ name, durationMs: null }];
    });
  const unique = uniqueRecords(records, `suites file ${filePath}`);
  return {
    records: unique,
    aggregateLabels: [...new Set(aggregateLabels)].sort(compareNames),
    notes: aggregateLabels.length
      ? [`excluded aggregate suites: ${[...new Set(aggregateLabels)].sort(compareNames).join(", ")}`]
      : [],
  };
}

function parseTimestamp(text) {
  // XCTest uses `YYYY-MM-DD HH:mm:ss.SSS`; treating the timestamp as UTC
  // makes planning independent of the machine timezone.
  const match = text.match(
    /\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\b/,
  );
  if (!match) return null;
  const normalized = match[0].replace(" ", "T");
  const milliseconds = Date.parse(`${normalized}Z`);
  return Number.isFinite(milliseconds) ? milliseconds : null;
}

function parseExplicitDurationMs(text) {
  const match = text.match(
    /\((\d+(?:\.\d+)?)\s*(?:seconds?|secs?|s)\)/i,
  );
  if (!match) return null;
  const seconds = Number(match[1]);
  if (!Number.isFinite(seconds) || seconds < 0) return null;
  return Math.max(1, Math.round(seconds * 1000));
}

function parseAggregateDeclaration(text) {
  const suites = text.match(/\b(\d+)\s+(?:test\s+)?suites?\b/i);
  if (suites) return { kind: "suites", count: Number(suites[1]) };
  const tests = text.match(/\b(?:Executed|Ran)\s+(\d+)\s+tests?\b/i);
  if (tests) return { kind: "tests", count: Number(tests[1]) };
  return null;
}

function parseLog(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, "utf8");
  } catch (error) {
    fail(`cannot read suite log ${filePath}: ${error.message}`);
  }

  const starts = new Map();
  const records = new Map();
  const aggregateLabels = new Set();
  const aggregateStack = [];
  const aggregateChecks = [];
  const leafEvents = [];
  const testCaseEvents = [];
  let lineNumber = 0;

  for (const line of text.split(/\r?\n/)) {
    lineNumber += 1;
    const suiteMatch = line.match(/^\s*Test Suite '(.+?)' (started|passed|failed) at\b(.*)$/);
    if (!suiteMatch) {
      if (/\bTest Suite\b/.test(line)) {
        fail(`suite log ${filePath} line ${lineNumber} is an unclassifiable Test Suite line`);
      }
      const declaration = parseAggregateDeclaration(line);
      if (declaration?.kind === "suites" && aggregateStack.length > 0) {
        aggregateStack[aggregateStack.length - 1].declaration = declaration;
      }
      const caseMatch = line.match(/^\s*Test Case '.*' (started|passed|failed) ?(.*)$/);
      if (caseMatch && caseMatch[1] !== "started") testCaseEvents.push(lineNumber);
      continue;
    }

    const name = requireSuiteName(suiteMatch[1], `suite log ${filePath} line ${lineNumber}`);
    const event = suiteMatch[2];
    const detail = suiteMatch[3];
    const timestamp = parseTimestamp(detail);
    const aggregate = isAggregateSuite(name);

    if (aggregate) aggregateLabels.add(name);
    if (event === "started") {
      if (timestamp !== null) starts.set(name, timestamp);
      if (aggregate) {
        aggregateStack.push({
          name,
          startLine: lineNumber,
          leafNames: new Set(),
          caseStart: testCaseEvents.length,
          declaration: parseAggregateDeclaration(detail),
        });
      } else {
        leafEvents.push({ name, lineNumber, event });
      }
      continue;
    }

    let durationMs = parseExplicitDurationMs(detail);
    if (durationMs === null && timestamp !== null && starts.has(name)) {
      const elapsed = timestamp - starts.get(name);
      if (elapsed >= 0) durationMs = Math.max(1, elapsed);
    }

    if (aggregate) {
      // Match the most recent same-name aggregate; malformed nesting remains
      // fail-closed rather than silently redefining the universe.
      let stackIndex = -1;
      for (let index = aggregateStack.length - 1; index >= 0; index -= 1) {
        if (aggregateStack[index].name === name) {
          stackIndex = index;
          break;
        }
      }
      if (stackIndex < 0) {
        fail(`suite log ${filePath} line ${lineNumber}: aggregate ${name} terminal without start`);
      }
      const state = aggregateStack.splice(stackIndex, 1)[0];
      const declaration = state.declaration || parseAggregateDeclaration(detail);
      if (declaration?.kind === "suites" && declaration.count !== state.leafNames.size) {
        fail(
          `suite log ${filePath} aggregate ${name} declared ${declaration.count} suites `
          + `but observed ${state.leafNames.size} leaf suites`,
        );
      }
      aggregateChecks.push({ name, declared: declaration, leafCount: state.leafNames.size });
    } else {
      leafEvents.push({ name, lineNumber, event });
      for (const aggregateState of aggregateStack) aggregateState.leafNames.add(name);
      const previous = records.get(name);
      // A repeated suite line is common in aggregate logs. Keep the largest
      // observed duration, while failed remains a terminal universe member.
      if (!previous || (durationMs ?? 0) > (previous.durationMs ?? 0)) {
        records.set(name, { name, durationMs, outcome: event });
      } else if (previous && previous.outcome !== "failed" && event === "failed") {
        records.set(name, { ...previous, outcome: "failed" });
      }
    }
  }

  for (const [name] of starts) {
    // Aggregate starts are validated by aggregateStack; leaf starts must have
    // a terminal event, otherwise the log is truncated/incomplete.
    if (!isAggregateSuite(name) && !records.has(name)) {
      fail(`suite log ${filePath} suite ${name} started but has no passed/failed terminal`);
    }
  }
  if (aggregateStack.length > 0) {
    fail(
      `suite log ${filePath} aggregate ${aggregateStack[aggregateStack.length - 1].name} `
      + "started but has no passed/failed terminal",
    );
  }
  if (records.size === 0) fail(`suite log ${filePath} contains no leaf test suites`);

  const uniqueAggregateLabels = [...aggregateLabels].sort(compareNames);
  return {
    records: uniqueRecords([...records.values()], `suite log ${filePath}`),
    aggregateLabels: uniqueAggregateLabels,
    aggregateChecks,
    notes: uniqueAggregateLabels.length
      ? [`excluded aggregate suites: ${uniqueAggregateLabels.join(", ")}`]
      : [],
  };
}

function compareNames(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function allocate(records, shardCount) {
  const hasHistory = records.some((record) => record.durationMs !== null);
  const ordered = [...records].sort((left, right) => {
    if (hasHistory) {
      const leftWeight = left.durationMs ?? 1;
      const rightWeight = right.durationMs ?? 1;
      if (leftWeight !== rightWeight) return rightWeight - leftWeight;
    }
    return compareNames(left.name, right.name);
  });

  const buckets = Array.from({ length: shardCount }, () => []);
  const totals = Array.from({ length: shardCount }, () => 0);
  for (const record of ordered) {
    let target = 0;
    for (let candidate = 1; candidate < shardCount; candidate += 1) {
      if (
        totals[candidate] < totals[target] ||
        (totals[candidate] === totals[target] && candidate < target)
      ) {
        target = candidate;
      }
    }
    buckets[target].push(record);
    totals[target] += hasHistory ? record.durationMs ?? 1 : 1;
  }

  // Filter order is lexical, not dependent on Map/object insertion behavior.
  for (const bucket of buckets) {
    bucket.sort((left, right) => compareNames(left.name, right.name));
  }
  return { buckets, totals, hasHistory };
}

function selectedFilters(records, shardCount, shardIndex) {
  return allocate(records, shardCount).buckets[shardIndex].map(
    (record) => `--filter=${record.name}`,
  );
}

function verifyPartition(records, shardCount) {
  const allocation = allocate(records, shardCount);
  const universe = records.map((record) => record.name).sort(compareNames);
  const flattened = allocation.buckets.flatMap((bucket) => bucket.map((record) => record.name));
  const seen = new Set();
  const duplicates = [];
  for (const name of flattened) {
    if (seen.has(name)) duplicates.push(name);
    seen.add(name);
  }
  if (duplicates.length > 0) {
    fail(`partition invariant failed: duplicate leaf suites: ${[...new Set(duplicates)].join(", ")}`);
  }
  const actual = [...seen].sort(compareNames);
  if (JSON.stringify(actual) !== JSON.stringify(universe)) {
    const missing = universe.filter((name) => !seen.has(name));
    const extra = actual.filter((name) => !universe.includes(name));
    fail(
      `partition invariant failed: union != universe (missing=${missing.join(", ") || "none"} `
      + `extra=${extra.join(", ") || "none"})`,
    );
  }
  return { suiteCount: universe.length, shardCounts: allocation.buckets.map((bucket) => bucket.length) };
}

function assert(condition, message) {
  if (!condition) fail(`selftest assertion failed: ${message}`);
}

function runSelftest() {
  const checks = [];
  const check = (id, action) => {
    try {
      action();
      checks.push({ id, passed: true });
    } catch (error) {
      checks.push({ id, passed: false, detail: error.message });
    }
  };

  check("uniform-even-distribution", () => {
    const records = ["a", "b", "c", "d", "e"].map((name) => ({
      name,
      durationMs: null,
    }));
    const first = allocate(records, 2);
    const second = allocate(records, 2);
    assert(!first.hasHistory, "uniform fixture unexpectedly has history");
    assert(
      JSON.stringify(first) === JSON.stringify(second),
      "uniform allocation is not deterministic",
    );
    assert(first.buckets[0].length === 3, "uniform shard 0 size");
    assert(first.buckets[1].length === 2, "uniform shard 1 size");
  });

  check("weighted-duration-distribution", () => {
    const records = [
      { name: "heavy", durationMs: 100 },
      { name: "medium", durationMs: 60 },
      { name: "small-a", durationMs: 10 },
      { name: "small-b", durationMs: 10 },
    ];
    const result = allocate(records, 2);
    assert(result.hasHistory, "weighted fixture lost history");
    assert(
      result.buckets[0].some((record) => record.name === "heavy"),
      "heavy suite was not assigned",
    );
    assert(
      result.totals[0] === 100 && result.totals[1] === 80,
      "weighted totals are not deterministic",
    );
  });

  check("more-shards-than-suites", () => {
    const records = ["only-a", "only-b"].map((name) => ({
      name,
      durationMs: null,
    }));
    const result = allocate(records, 4);
    assert(result.buckets.length === 4, "shard count changed");
    assert(result.buckets[3].length === 0, "empty shard was not preserved");
    assert(selectedFilters(records, 4, 3).length === 0, "empty output");
  });

  check("empty-input-fails-closed", () => {
    let threw = false;
    try {
      uniqueRecords([], "empty fixture");
    } catch {
      threw = true;
    }
    assert(threw, "empty input was accepted");
  });

  check("log-line-parser-shape", () => {
    const tempPath = `${process.env.TMPDIR || "/tmp"}/tatwo-test-shard-selftest-${process.pid}.log`;
    const text = [
      "Test Suite 'slow' started at 2026-01-01 00:00:00.000.",
      "Test Suite 'slow' failed at 2026-01-01 00:00:02.000.",
      "  Test Suite 'fast' passed at 2026-01-01 00:00:02.100.",
      "Test Suite 'All tests' started at 2026-01-01 00:00:02.000.",
      "Test Suite 'All tests' passed at 2026-01-01 00:00:02.100.",
    ].join("\n");
    fs.writeFileSync(tempPath, text);
    try {
      const records = parseLog(tempPath);
      assert(records.records.length === 2, "log parser suite count");
      assert(records.records.some((record) => record.name === "slow"), "failed suite is in universe");
      assert(records.aggregateLabels.includes("All tests"), "aggregate label was recorded");
      assert(verifyPartition(records.records, 2).suiteCount === 2, "partition invariant");
      assert(
        records.records.find((record) => record.name === "slow").durationMs === 2000,
        "log parser duration",
      );
    } finally {
      try {
        fs.unlinkSync(tempPath);
      } catch {
        // Selftest cleanup is best effort and only touches its own fixture.
      }
    }
  });

  check("aggregate-and-malformed-lines-fail-closed", () => {
    const tempPath = `${process.env.TMPDIR || "/tmp"}/tatwo-test-shard-selftest-bad-${process.pid}.log`;
    const malformed = [
      "Test Suite 'All tests' started at 2026-01-01 00:00:00.000.",
      "Test Suite 'leaf' passed at 2026-01-01 00:00:00.100.",
      "Test Suite 'All tests' passed at 2026-01-01 00:00:00.100. 2 suites",
      "Test Suite malformed",
    ].join("\n");
    fs.writeFileSync(tempPath, malformed);
    try {
      let threw = false;
      try { parseLog(tempPath); } catch (error) {
        threw = /declared 2 suites|unclassifiable/.test(error.message);
      }
      assert(threw, "malformed aggregate/suite line was accepted");
    } finally {
      try { fs.unlinkSync(tempPath); } catch {}
    }
  });

  check("partition-invariant-all-shard-counts", () => {
    const records = ["leaf-a", "leaf-b", "leaf-c", "leaf-d"].map((name) => ({
      name,
      durationMs: null,
    }));
    for (const shardCount of [2, 3, 5]) {
      const result = verifyPartition(records, shardCount);
      assert(result.suiteCount === 4, `partition universe for N=${shardCount}`);
    }
  });

  const passed = checks.every((check) => check.passed);
  const receipt = {
    schema: SCHEMA,
    passed,
    checks,
  };
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
  return passed ? 0 : 1;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }
  if (options.selftest) return runSelftest();

  const parsed = options.suitesFile
    ? readSuitesFile(options.suitesFile)
    : parseLog(options.fromLog);
  if (options.verifyPartition) {
    const verification = verifyPartition(parsed.records, options.shards);
    process.stderr.write(
      `partition verified: leafUniverse=${verification.suiteCount} `
      + `shardCounts=${verification.shardCounts.join(",")}\n`,
    );
  }
  for (const note of parsed.notes || []) process.stderr.write(`note: ${note}\n`);
  const filters = selectedFilters(parsed.records, options.shards, options.index);
  if (filters.length > 0) process.stdout.write(`${filters.join("\n")}\n`);
  return 0;
}

try {
  process.exitCode = main();
} catch (error) {
  process.stderr.write(`FAIL\nfailure: ${error.message}\n`);
  process.exitCode = 2;
}
