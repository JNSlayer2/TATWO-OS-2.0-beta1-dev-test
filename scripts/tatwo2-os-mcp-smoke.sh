#!/bin/zsh
# 對 os.sock 送 list_rooms；socket 不存在印 OS_SOCK_MISSING。
set -u
SOCK="$HOME/Library/Application Support/tatwo2/live/os.sock"
if [[ ! -e "$SOCK" ]]; then
  print -r -- 'OS_SOCK_MISSING'
  exit 1
fi
node --input-type=module -e '
import net from "node:net";
import os from "node:os";
import path from "node:path";
const socketPath = path.join(os.homedir(), "Library", "Application Support", "tatwo2", "live", "os.sock");
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let data = "";
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.end(JSON.stringify({ id: 1, method, params }) + "\n"));
    socket.on("data", chunk => { data += chunk; });
    socket.on("error", reject);
    socket.on("close", () => {
      try {
        resolve(JSON.parse(data.trim()));
      } catch (error) { reject(error); }
    });
  });
}
try {
  console.log(JSON.stringify(await call("list_rooms", {})));
} catch (error) {
  console.error(String(error?.stack || error));
  process.exitCode = 1;
}
'
