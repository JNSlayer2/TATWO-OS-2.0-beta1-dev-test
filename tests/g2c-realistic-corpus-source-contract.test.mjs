import assert from "node:assert/strict";
import fs from "node:fs";

const source = fs.readFileSync("Tools/G2CKernelExam/main.swift", "utf8");
const corpus = source.match(
  /private static func realisticCorpus[\s\S]*?private static func curveStats/,
)?.[0] ?? "";

assert.match(corpus, /for turn in 1\.\.\.30/);
assert.match(corpus, /USER:/);
assert.match(corpus, /ASSISTANT:/);
assert.match(corpus, /TOOL_OUTPUT:/);
assert.match(corpus, /1_128/);
assert.match(corpus, /3_000/);
assert.match(corpus, /```swift/);
assert.match(corpus, /"component":"kernel"/);
assert.doesNotMatch(corpus, /\bDate\b|random|UUID/);
assert.match(source, /for turn in 10\.\.\.30/);
assert.match(source, /"p50"/);
assert.match(source, /"p95"/);
assert.match(source, /"cumulative"/);

console.log("PASS g2c realistic corpus source contract");
