#!/usr/bin/env node

const tools = [
  tool("tatwo_app_read_os_state", "Read the current Tatwo OS/App state.", {}),
  tool("tatwo_app_list_loops", "List current Work OS loops and their states.", {}),
  tool("tatwo_app_switch_tab", "Switch the Tatwo App to a named tab.", {
    tab: { type: "string", enum: ["chat", "cli", "ultrawork", "plugins", "devices", "settings"] }
  }, ["tab"]),
  tool("tatwo_app_set_sidebar_pinned", "Pin or unpin the left sidebar.", {
    pinned: { type: "boolean" }
  }, ["pinned"]),
  tool("tatwo_app_set_tab_setting", "Set one allowlisted setting for a Tatwo tab.", {
    tab: { type: "string" },
    key: { type: "string" },
    value: {}
  }, ["tab", "key", "value"])
];

function tool(name, description, properties, required = []) {
  return {
    name, description,
    inputSchema: { type: "object", properties, required, additionalProperties: false }
  };
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { buffer += chunk; drain(); });
process.stdin.resume();

function drain() {
  for (;;) {
    const newline = buffer.indexOf("\n");
    if (newline < 0) return;
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line) handle(line);
  }
}

function handle(line) {
  let request;
  try { request = JSON.parse(line); }
  catch (error) { return sendError(null, -32700, `parse error: ${error.message}`); }
  if (request.id == null) return;
  if (request.method === "initialize") {
    return send(request.id, {
      protocolVersion: request.params?.protocolVersion ?? "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "tatwo-app", version: "1.0.0" }
    });
  }
  if (request.method === "ping") return send(request.id, {});
  if (request.method === "tools/list") return send(request.id, { tools });
  if (request.method !== "tools/call") {
    return sendError(request.id, -32601, `unknown method: ${request.method}`);
  }
  void call(request);
}

async function call(request) {
  const name = String(request.params?.name ?? "");
  if (!tools.some(item => item.name === name)) {
    return sendError(request.id, -32602, `unknown tool: ${name}`);
  }
  const base = requiredEnvironment("TATWO_APP_MCP_URL");
  try {
    const response = await fetch(new URL("/tools/call", base), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        tool: `tatwo.app.${name.slice("tatwo_app_".length)}`,
        arguments: request.params?.arguments ?? {}
      })
    });
    const result = await response.json();
    send(request.id, {
      content: [{ type: "text", text: JSON.stringify(result) }],
      isError: !result?.ok
    });
  } catch (error) {
    send(request.id, {
      content: [{ type: "text", text: `Tatwo App tool unavailable: ${error.message}` }],
      isError: true
    });
  }
}

function requiredEnvironment(name) {
  const value = String(process.env[name] ?? "").trim();
  if (!value) throw new Error(`missing_environment:${name}`);
  return value;
}
function send(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}
function sendError(id, code, message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
}
