import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const bridge = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm';
const run = (cmd, args) => {
  const r = spawnSync(cmd, args, {cwd: root, encoding:'utf8', timeout:90000});
  if (r.status !== 0) throw new Error(`${cmd}: ${r.error ?? ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
};
const [mode, ref] = process.argv.slice(2);
if (!['--fixture', '--checks', '--log'].includes(mode)) {
  throw new Error('Usage: browser-pump-probe.sh --fixture <before-ref> | --checks | --log <telemetry-file>');
}
if (mode === '--log') {
  // Only emit the opt-in numeric probe record, never copy browsing telemetry.
  const file = fs.openSync(ref, 'r');
  let text;
  try {
    const size = fs.fstatSync(file).size, bytes = Buffer.alloc(Math.min(size, 512 * 1024));
    const read = fs.readSync(file, bytes, 0, bytes.length, size - bytes.length);
    text = bytes.subarray(0, read).toString('utf8');
  } finally { fs.closeSync(file); }
  const lines = text.split('\n').filter(s => s.includes('phase=w60_pump_probe event=end'));
  const line = lines.at(-1);
  if (!line) throw new Error('No completed opt-in 5s runtime probe; launch a disposable candidate with TATWO_CEF_PUMP_PROBE=1');
  const value = key => Number(line.match(new RegExp(`\\b${key}=(\\d+)\\b`))?.[1] ?? NaN);
  const result = {scope:'cef_runtime', pid:value('pid'), duration_ms:value('durationMs'),
    cef_work_calls:value('doWorkCount'), main_runloop_wakeups:value('mainWakeups')};
  if (Object.values(result).some(v => typeof v === 'number' && !Number.isFinite(v))) throw new Error('Incomplete probe record');
  console.log(JSON.stringify(result));
} else {
  const work = path.join(root, '.build/w60/pump');
  fs.mkdirSync(work, {recursive:true});
  const template = fs.readFileSync(path.join(root, 'tests/fixtures/browser-pump-probe.mm.in'), 'utf8');
  const current = fs.readFileSync(path.join(root, bridge), 'utf8');
  function measure(source, name, checks = false) {
    let a = source.indexOf('#pragma mark - W60 Scheduled pump');
    if (a < 0) a = source.indexOf('#pragma mark - External message pump');
    if (a < 0) a = source.indexOf('void StartCEFMessagePumpIdleTimer()');
    const b = source.indexOf('void QueueImmediateCEFMessagePumpWorkOnMainQueue()', a);
    if (a < 0 || b <= a) throw new Error('Missing production scheduler');
    const file = path.join(work, `${name}.mm`), binary = path.join(work, name);
    // The optional live-runtime probe is not part of this scheduler fixture.
    const scheduler = source.slice(a,b).replace('W60StartRuntimePumpProbe();', '');
    const currentTemplate = source.includes('#pragma mark - External message pump')
      ? template.replace('dispatch_source_t g_message_pump_idle_timer', 'NSTimer *g_message_pump_idle_timer')
      : template;
    fs.writeFileSync(file, currentTemplate.replace('// INSERT scheduler', scheduler));
    run('xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-fblocks', '-framework','AppKit', file, '-o', binary]);
    const output = run(binary, [checks ? 'checks' : 'probe']).trim();
    return checks ? output : JSON.parse(output);
  }
  if (mode === '--checks') console.log(measure(current, 'checks', true));
  else {
    if (!ref || ref.startsWith('-')) throw new Error('Explicit before revision is required');
    const before = run('git', ['show', `${ref}:${bridge}`]);
    console.log(JSON.stringify({before: measure(before, 'before'), after: measure(current, 'after'),
      limitation:'CEF call is stubbed; baseline includes global idle timer only, not per-tab loading timers. Runtime A/B still required.'}));
  }
}
