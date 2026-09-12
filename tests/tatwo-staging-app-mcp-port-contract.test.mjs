import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const stagingScriptPath = path.join(
  repoRoot,
  "script",
  "build_staging_app.sh",
);
const modelRuntimeScriptPath = path.join(
  repoRoot,
  "scripts",
  "tatwo-stage-model-runtimes.sh",
);

test("staging bundle records one App MCP port in launch environment and receipt", () => {
  const source = readFileSync(stagingScriptPath, "utf8");
  const modelRuntimeSource = readFileSync(modelRuntimeScriptPath, "utf8");

  assert.match(
    modelRuntimeSource,
    /SUBSCRIPTION_CODE_MODE_HOST_SOURCE="\$\{TATWO_SUBSCRIPTION_CODE_MODE_HOST_SOURCE:-\$\(dirname "\$SUBSCRIPTION_RUNTIME_SOURCE"\)\/codex-code-mode-host\}"/,
  );
  assert.match(
    modelRuntimeSource,
    /SUBSCRIPTION_CODE_MODE_HOST_RELATIVE="Contents\/Helpers\/codex-code-mode-host"/,
  );
  assert.match(
    modelRuntimeSource,
    /cp\s+\\?\s*"\$SUBSCRIPTION_CODE_MODE_HOST_SOURCE"\s+\\?\s*"\$SUBSCRIPTION_CODE_MODE_HOST"/,
  );
  assert.match(
    source,
    /source "\$ROOT_DIR\/scripts\/tatwo-stage-model-runtimes\.sh"/,
  );
  assert.match(source, /tatwo_resolve_model_runtimes "\$APP_BUNDLE"/);
  assert.match(source, /tatwo_stage_model_runtimes "\$APP_BUNDLE"/);
  assert.match(
    source,
    /"subscriptionCodeModeHostSHA256": "\$SUBSCRIPTION_CODE_MODE_HOST_SHA256"/,
  );
  assert.match(
    source,
    /STAGING_RUNTIME_ROOT="\$\{TATWO_STAGING_RUNTIME_ROOT:-\$\(/,
  );
  assert.match(source, /APP_SUPPORT="\$STAGING_RUNTIME_ROOT\/app-support"/);
  assert.match(source, /APP_STATE="\$STAGING_RUNTIME_ROOT\/state"/);
  assert.match(source, /"runtimeRoot": "\$STAGING_RUNTIME_ROOT"/);
  assert.match(source, /"externalRuntimeAllowed": \$EXTERNAL_RUNTIME_ALLOWED/);
  assert.match(source, /"HOME=\$STAGING_HOME"/);
  assert.match(
    source,
    /"TATWO_ULTRAWORK_APP_SUPPORT=\$APP_SUPPORT"/,
  );
  assert.doesNotMatch(source, /APP_SUPPORT="\$STAGING_ROOT\/app-support"/);
  assert.match(
    source,
    /APP_MCP_PORT="\$\{TATWO_STAGING_APP_MCP_PORT:-\$\(select_available_loopback_port\)\}"/,
  );
  assert.match(
    source,
    /CHAT_WORKDIR="\$\{TATWO_STAGING_CHAT_WORKDIR:-\$ROOT_DIR\}"/,
  );
  assert.match(
    source,
    /<key>TATWO_ULTRAWORK_APP_MCP_PORT<\/key>\s*<string>\$APP_MCP_PORT<\/string>/,
  );
  assert.match(
    source,
    /<key>TATWO_ULTRAWORK_CHAT_WORKDIR<\/key>\s*<string>\$CHAT_WORKDIR<\/string>/,
  );
  assert.match(source, /"appMCPPort": \$APP_MCP_PORT/);
  assert.match(
    source,
    /"appMCPURL": "http:\/\/127\.0\.0\.1:\$APP_MCP_PORT"/,
  );
  assert.match(source, /"chatWorkdir": "\$CHAT_WORKDIR"/);
  assert.match(
    source,
    /SWIFT_BUILD_ARGS=\(--package-path "\$ROOT_DIR" -c debug --jobs 2\)/,
  );
  assert.match(
    source,
    /printf 'TATWO_APP_MCP_URL=http:\/\/127\.0\.0\.1:%s\\n' "\$APP_MCP_PORT"/,
  );
  assert.match(
    source,
    /printf 'TATWO_CHAT_WORKDIR=%s\\n' "\$CHAT_WORKDIR"/,
  );
  assert.doesNotMatch(source, /printf 'APP_MCP_URL=/);
});

test("staging build rejects external mutable runtime before Swift build", () => {
  const result = spawnSync(stagingScriptPath, {
    cwd: repoRoot,
    env: {
      ...process.env,
      TATWO_STAGING_RUNTIME_ROOT: "/Volumes/tatwo-forbidden-runtime",
    },
    encoding: "utf8",
  });

  assert.notEqual(result.status, 0);
  assert.match(
    result.stderr,
    /staging mutable runtime roots must stay off \/Volumes by default/,
  );
  assert.doesNotMatch(result.stdout + result.stderr, /Building for debugging/);
});

test("staging build rejects an invalid App MCP port before Swift build", () => {
  const result = spawnSync(stagingScriptPath, {
    cwd: repoRoot,
    env: {
      ...process.env,
      TATWO_STAGING_APP_MCP_PORT: "0",
    },
    encoding: "utf8",
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /invalid TATWO_STAGING_APP_MCP_PORT: 0/);
  assert.doesNotMatch(result.stdout + result.stderr, /Building for debugging/);
});

test("staging build rejects an occupied App MCP port before Swift build", async (t) => {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const address = server.address();
  assert.equal(typeof address, "object");
  assert.ok(address);
  const result = spawnSync(stagingScriptPath, {
    cwd: repoRoot,
    env: {
      ...process.env,
      TATWO_STAGING_APP_MCP_PORT: String(address.port),
    },
    encoding: "utf8",
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /staging App MCP port is unavailable/);
  assert.doesNotMatch(result.stdout + result.stderr, /Building for debugging/);
});
