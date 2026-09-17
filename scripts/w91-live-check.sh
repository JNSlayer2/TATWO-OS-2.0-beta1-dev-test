#!/bin/bash
# Read-only; the lead runs this on each physical device. No align/wake/fetch RPC.
set -euo pipefail
exec python3 - "$@" <<'PY'
import json, os, pathlib, socket, sys
live = pathlib.Path(os.environ.get('TATWO2_LIVE_ROOT',
    str(pathlib.Path.home() / 'Library/Application Support/tatwo2/live')))
path = sys.argv[1] if len(sys.argv) > 1 else str(live / 'os.sock')
def rpc(method):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(15)
        client.connect(path)
        client.sendall((json.dumps({'id': 'w91-' + method, 'method': method, 'params': {}}) + '\n').encode())
        client.shutdown(socket.SHUT_WR)
        chunks = bytearray()
        while not chunks.endswith(b'\n'):
            part = client.recv(65536)
            if not part: break
            chunks.extend(part)
            if len(chunks) > 16 * 1024 * 1024: raise RuntimeError('response too large')
        response = json.loads(chunks)
        if not response.get('ok'): raise RuntimeError(str(response.get('error', 'RPC failed')))
        return response['result']
status = rpc('device_status')
devices = rpc('list_devices').get('devices', [])
print('device_status:', json.dumps({key: status.get(key) for key in ('identity', 'appVersion')}, ensure_ascii=False))
# The current read-only status RPC does not expose dispatch receipts. Read the
# adjacent state file without constructing DeviceDispatch or triggering a sync.
state = pathlib.Path(path).parent / 'dispatch/state.json'
try:
    receipts = json.loads(state.read_text()).get('receipts', {})
except FileNotFoundError:
    receipts = {}
    print('receipts: unavailable (state file missing; not converged)')
for device in devices:
    receipt = receipts.get(device['id'], {})
    print(json.dumps({'device': device['id'], 'name': device.get('name'),
        'lastSeenAt': device.get('lastSeenAt'), 'lastEndpoint': device.get('lastEndpoint'),
        'phase': receipt.get('phase', 'unknown'), 'detail': receipt.get('detail'),
        'receiptUpdated': receipt.get('updated')}, ensure_ascii=False))
for identity, receipt in receipts.items():
    if not any(row['id'] == identity for row in devices):
        print(json.dumps({'device': identity, 'phase': receipt.get('phase'),
            'detail': receipt.get('detail'), 'lastEndpoint': None}, ensure_ascii=False))
PY
