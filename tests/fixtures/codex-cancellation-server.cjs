// Test-only native peer. No model, auth, MCP, network service or real Codex.
const fs = require('node:fs');
const net = require('node:net');
const readline = require('node:readline');
if (process.argv.includes('--version')) {
  console.log('codex-cancellation-fixture 1');
  process.exit(0);
}
const pending = [];
let control;
const server = net.createServer(socket => {
  control = socket;
  for (const line of pending.splice(0)) socket.write(line);
  readline.createInterface({ input: socket }).on('line', line => {
    process.stdout.write(line + '\n');
  });
});
server.listen(process.env.CANCEL_SOCKET);
readline.createInterface({ input: process.stdin }).on('line', line => {
  fs.appendFileSync(process.env.CANCEL_CAPTURE, line + '\n');
  if (control) control.write(line + '\n');
  else pending.push(line + '\n');
}).on('close', () => process.exit(0));
