import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const cliEntrypoint = path.join(
  repoRoot,
  "Tools",
  "TatwoUltraworkCLI",
  "Sources",
  "TatwoUltraworkCLI",
  "main.swift",
);

test("main.swift uses one portable top-level entrypoint instead of @main", () => {
  const source = fs.readFileSync(cliEntrypoint, "utf8");

  assert.doesNotMatch(
    source,
    /^\s*@main\s*$/m,
    "a file named main.swift must not also declare @main",
  );
  assert.equal(
    source.match(/^\s*TatwoUltraworkCLI\.main\(\)\s*$/gm)?.length ?? 0,
    1,
    "main.swift must invoke TatwoUltraworkCLI.main() exactly once",
  );
});
