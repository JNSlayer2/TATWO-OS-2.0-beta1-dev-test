#!/usr/bin/env node

/**
 * Build-time os.md §9 manifest generator.
 *
 * The app never reads the external Work OS volume at runtime. This script is
 * the only place that reads os.md and emits the JSON consumed by SwiftPM.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const defaultOutputPath = path.join(repoRoot, "config", "os-manifest.json");
// Logical source identity only — never write absolute host paths into the
// shipped manifest (MF-8 privacy). Source path must be provided by the caller
// (CLI argument); no private absolute-path default is allowed.
const SOURCE_ID = "TATWO-ULTRAWORKos/os.md";
// Package.swift already bundles this existing resource. Keep the resource
// filename stable and replace its build-time contents with the JSON manifest.
const swiftPMResourcePath = path.join(
  repoRoot,
  "Apps",
  "TatwoUltraworkMac",
  "Resources",
  "os-architecture-standard.md",
);

function usage() {
  process.stderr.write(
    [
      "Usage:",
      '  node scripts/tatwo-osmd-manifest.mjs generate "/path/to/os.md"',
      '  node scripts/tatwo-osmd-manifest.mjs --check "/path/to/os.md"',
      "",
      "generate writes config/os-manifest.json and the existing SwiftPM resource.",
      "--check exits 0 with SKIP volume-absent when the source volume is absent.",
      "",
    ].join("\n"),
  );
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function cleanItem(line) {
  return line
    .trim()
    .replace(/^[-*+]\s+/, "")
    .replace(/^#{1,6}\s+/, "")
    .replace(/\s+/g, " ");
}

function parseOsmd(sourceText, generatedAt) {
  const lines = sourceText.replace(/\r\n?/g, "\n").split("\n");
  const rootIndex = lines.findIndex((line) => /^##\s+9\.\s+/.test(line));
  if (rootIndex < 0) {
    throw new Error("os.md §9 heading not found");
  }

  const rootEnd = lines.findIndex(
    (line, index) => index > rootIndex && /^##\s+/.test(line),
  );
  const endIndex = rootEnd < 0 ? lines.length : rootEnd;
  const sectionHeading = /^###\s+(9\.\d+)\s+(.+?)\s*$/;
  const subsectionHeading = /^####\s+(.+?)\s*$/;

  const sections = [];
  const firstSectionIndex = lines.findIndex(
    (line, index) => index > rootIndex && sectionHeading.test(line),
  );
  const metaEnd = firstSectionIndex < 0 ? endIndex : firstSectionIndex;
  const metaLines = lines
    .slice(rootIndex + 1, metaEnd)
    .map(cleanItem)
    .filter(Boolean);
  const metaRuleLine = metaLines.shift();
  if (metaRuleLine) {
    const match = metaRuleLine.match(/^\*\*(.+?)\*\*[：:]\s*(.*)$/);
    sections.push({
      id: "meta-rule",
      title: match?.[1] ?? "元規則（防漂移）",
      items: [match?.[2] || metaRuleLine],
    });
    sections[0].items.push(...metaLines);
  }

  let current = null;
  for (let index = firstSectionIndex; index >= 0 && index < endIndex; index += 1) {
    const line = lines[index];
    const heading = line.match(sectionHeading);
    if (heading) {
      current = { id: heading[1], title: heading[2], items: [] };
      sections.push(current);
      continue;
    }
    if (!current) continue;

    const subsection = line.match(subsectionHeading);
    if (subsection) {
      current.items.push(subsection[1]);
      continue;
    }

    const item = cleanItem(line);
    if (item) current.items.push(item);
  }

  // Drift guard, not a growth cap: §9 may gain sections as architecture is
  // ratified (TODO rule: settled closed-loop architecture is promoted here).
  // What must hold is that the set starts at 9.1 and is contiguous with no
  // gaps, duplicates or reordering — a missing or renumbered section is drift.
  const actualIDs = sections.filter((section) => section.id !== "meta-rule").map((section) => section.id);
  if (actualIDs.length === 0) {
    throw new Error("os.md §9 has no numbered sections");
  }
  const expectedIDs = actualIDs.map((_, index) => `9.${index + 1}`);
  if (JSON.stringify(actualIDs) !== JSON.stringify(expectedIDs)) {
    throw new Error(
      `os.md §9 sections must be contiguous from 9.1: expected ${expectedIDs.join(",")}, got ${actualIDs.join(",")}`,
    );
  }
  for (const section of sections) {
    if (!section.title || section.items.length === 0) {
      throw new Error(`empty os.md manifest section: ${section.id}`);
    }
  }

  return {
    schema: "TatwoOsManifestV1",
    // Privacy: fixed logical id only — never absolute host paths (MF-8).
    sourceId: SOURCE_ID,
    sourceSHA256: sha256(Buffer.from(sourceText, "utf8")),
    generatedAt,
    sections,
  };
}

function readSource(sourcePath) {
  return fs.readFileSync(sourcePath);
}

function writeManifest(manifest) {
  const serialized = `${JSON.stringify(manifest, null, 2)}\n`;
  fs.mkdirSync(path.dirname(defaultOutputPath), { recursive: true });
  fs.writeFileSync(defaultOutputPath, serialized, "utf8");
  // The package target already bundles this existing path. It is a generated
  // build input, not a second source of truth.
  if (fs.existsSync(swiftPMResourcePath)) {
    fs.writeFileSync(swiftPMResourcePath, serialized, "utf8");
  }
  process.stdout.write(
    `GENERATED ${path.relative(repoRoot, defaultOutputPath)} sections=${manifest.sections.length} sourceSHA256=${manifest.sourceSHA256}\n`,
  );
}

function loadManifest() {
  const text = fs.readFileSync(defaultOutputPath, "utf8");
  return JSON.parse(text);
}

function runCheck(sourcePath) {
  let sourceBytes;
  try {
    sourceBytes = readSource(sourcePath);
  } catch (error) {
    if (error?.code === "ENOENT" && sourcePath.startsWith("/Volumes/")) {
      process.stdout.write("SKIP volume-absent\n");
      return 0;
    }
    throw error;
  }

  const manifest = loadManifest();
  const actualHash = sha256(sourceBytes);
  if (manifest?.schema !== "TatwoOsManifestV1") {
    process.stderr.write("CHECK FAIL invalid manifest schema\n");
    return 1;
  }
  if (manifest.sourceSHA256 !== actualHash) {
    process.stderr.write(
      `CHECK FAIL sourceSHA256 manifest=${manifest.sourceSHA256} live=${actualHash}\n`,
    );
    return 1;
  }
  process.stdout.write(`CHECK PASS sourceSHA256=${actualHash}\n`);
  return 0;
}

function main(argv) {
  const command = argv[0];
  if (!command || command === "-h" || command === "--help") {
    usage();
    return command ? 0 : 2;
  }

  if (command === "generate") {
    // Absolute path is read-only input; only sourceId + sourceSHA256 are written.
    // Path must be provided by argument — no private absolute-path default.
    if (!argv[1]) {
      usage();
      process.stderr.write("ERROR source path must be provided as an argument (no default path)\n");
      return 2;
    }
    const sourcePath = path.resolve(argv[1]);
    const sourceBytes = readSource(sourcePath);
    const sourceText = sourceBytes.toString("utf8");
    const manifest = parseOsmd(sourceText, new Date().toISOString());
    writeManifest(manifest);
    return 0;
  }

  if (command === "check" || command === "--check") {
    // Manifest no longer stores sourcePath — only sourceId + sourceSHA256.
    // Path must be provided by argument — no private absolute-path default.
    if (!argv[1]) {
      usage();
      process.stderr.write("ERROR source path must be provided as an argument (no default path)\n");
      return 2;
    }
    const sourcePath = path.resolve(argv[1]);
    return runCheck(sourcePath);
  }

  usage();
  throw new Error(`unknown command: ${command}`);
}

try {
  process.exitCode = main(process.argv.slice(2));
} catch (error) {
  process.stderr.write(`ERROR ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
