import assert from "node:assert/strict";
import fs from "node:fs";

const driver = fs.readFileSync("Tools/AgentKernelDriver/main.swift", "utf8");
const selftest = fs.readFileSync(
  "Tools/AgentKernelDriver/selftest-checkpoint-handoff.sh",
  "utf8",
);

assert.match(driver, /transport == "grok"[\s\S]*grok-isolated/);
assert.match(driver, /\["-p", prompt, "--output-format", "streaming-json"\]/);
assert.match(driver, /\["-p", prompt, "--output-format", "json"\]/);
assert.match(driver, /DispatchQueue\.global\(qos: \.utility\)\.async[\s\S]*readDataToEndOfFile/);
assert.match(driver, /AGENT_KERNEL_TRANSPORT_TIMEOUT_SECONDS/);
assert.match(driver, /timed out after/);
assert.match(
  driver,
  /for key in \["result", "text", "content", "message"\][\s\S]*candidates\.append/,
);
assert.match(driver, /CHECKPOINT_ONLY=true/);
assert.match(driver, /CONTINUATION=null/);
assert.match(driver, /var messages = checkpointOnly \? \[\]/);
assert.match(driver, /var results = checkpointOnly \? \[\]/);
assert.match(driver, /PortableCheckpointV1\.decodeAndValidate/);
assert.doesNotMatch(
  driver.match(/private static func savePortableCheckpoint[\s\S]*?\n  \}/)?.[0] ?? "",
  /session|thread|conversation/i,
);

assert.match(selftest, /kill -KILL/);
assert.match(selftest, /KILL_STATUS.*137/s);
assert.match(selftest, /--checkpoint-only/);
assert.match(selftest, /! grep -R -E '314159\|271828\|585987'/);
assert.match(
  selftest,
  /PASS kill=SIGKILL checkpoint_only=true/,
);

console.log("PASS agent-kernel-driver K3 source contract");
