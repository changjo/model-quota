#!/usr/bin/python3
"""Local protocol peer; no network, credentials, or model calls."""
import json
import os
import sys
import time

directory = os.path.dirname(os.path.realpath(__file__))
mode = open(os.path.join(directory, 'mode')).read().strip()
with open(os.path.join(directory, 'pid'), 'w') as f:
    f.write(str(os.getpid()))
with open(os.path.join(directory, 'response-redacted.json')) as f:
    snapshot = json.load(f)['result']
initialized = False
acknowledged = False

def send(message):
    print(json.dumps(message), flush=True)

try:
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get('method')
        ident = message.get('id')
        if method == 'initialize':
            if initialized:
                send({'id': ident, 'error': {'code': -32600, 'message': 'Already initialized'}})
                continue
            initialized = True
            send({'id': ident, 'result': {'userAgent': 'fake'}})
        elif method == 'initialized':
            acknowledged = initialized
        elif method == 'account/read' and acknowledged:
            assert message['params']['refreshToken'] is False
            account = None if mode == 'signed-out' else {'type': 'chatgpt', 'email': 'unused@example.invalid', 'planType': 'prolite'}
            send({'id': ident, 'result': {'account': account, 'requiresOpenaiAuth': True}})
        elif method == 'account/rateLimits/read' and acknowledged:
            if mode == 'timeout':
                time.sleep(20)
            elif mode == 'crash':
                sys.exit(2)
            elif mode == 'malformed':
                print('not json', flush=True)
            else:
                # Ignore a response with an unknown id; handle interleaved notifications.
                send({'id': 98765, 'result': {}})
                if mode == 'notify':
                    send({'method': 'account/rateLimits/updated', 'params': {'rateLimits': {'limitId': 'codex'}}})
                if mode == 'server-request':
                    send({'id': 'server-action', 'method': 'item/commandExecution/requestApproval', 'params': {}})
                # Two writes exercise incremental framing without depending on read boundaries.
                payload = json.dumps({'id': ident, 'result': snapshot})
                sys.stdout.write(payload[:30])
                sys.stdout.flush()
                sys.stdout.write(payload[30:] + '\n')
                sys.stdout.flush()
        elif ident == 'server-action':
            assert message.get('error', {}).get('code') == -32601
            with open(os.path.join(directory, 'rejected'), 'w') as f:
                f.write('yes')
        elif ident is not None:
            send({'id': ident, 'error': {'code': -32000, 'message': 'Invalid sequence'}})
finally:
    if mode == 'slow-exit':
        time.sleep(0.25)
    with open(os.path.join(directory, 'exited'), 'w') as f:
        f.write('yes')
