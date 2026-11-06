"""Exercise the desktop's real HTTP process using an isolated synthetic book."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

import httpx


def test_desktop_process_sync_import_edit_export_and_graceful_restart(tmp_path):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    environment = dict(os.environ, LEDGER_API_TOKEN='synthetic-desktop-token-123456789',
                       LEDGER_DB_PATH=str(tmp_path / 'synthetic.sqlite3'))
    header = {'Authorization': 'Bearer ' + environment['LEDGER_API_TOKEN']}
    ledger_id = None
    for iteration in range(2):
        process = subprocess.Popen(
            [sys.executable, '-m', 'app.desktop_runner', '--host', '127.0.0.1', '--port', str(port)],
            cwd=Path(__file__).resolve().parents[1], env=environment,
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            with httpx.Client(base_url=f'http://127.0.0.1:{port}', trust_env=False, timeout=2) as client:
                deadline = time.monotonic() + 12
                while True:
                    assert process.poll() is None, 'Desktop-owned server exited before readiness'
                    try:
                        health = client.get('/health')
                        if health.status_code == 200:
                            break
                    except httpx.TransportError:
                        pass
                    assert time.monotonic() < deadline, 'Health check did not become ready'
                    time.sleep(.05)
                assert health.json() == {'status': 'ok', 'service': 'private-ledger'}
                assert client.get('/api/v1/sync').status_code == 401
                snapshot = client.get('/api/v1/sync', headers=header).json()
                if iteration == 0:
                    ledger_id = snapshot['ledger_id']
                    preview = client.post('/api/v1/imports/preview', headers=header,
                        data={'source': 'generic'}, files={'file': ('synthetic.csv',
                        b'occurred_at,amount,direction,merchant,external_id\n2026-10-28,12.34,expense,Synthetic shop,fixture-1\n',
                        'text/csv')}).json()
                    commit = client.post(f"/api/v1/imports/{preview['preview_id']}/commit", headers=header)
                    assert commit.status_code == 200
                    assert commit.json()['imported'] == 1
                    row = client.get('/api/v1/sync', headers=header).json()['transactions'][0]
                    edited = client.post('/api/v1/edits', headers=header, json={
                        'operation_id': '36c349db-0b8c-4521-bd7f-85800babcdeb', 'transaction_id': row['id'],
                        'expected_version': row['version'], 'changes': {'category': 'Synthetic category'},
                    })
                    assert edited.status_code == 200
                    exported = client.get('/api/v1/export.csv?redact=true', headers=header)
                    assert exported.status_code == 200
                    assert 'Synthetic shop' not in exported.text
                    assert 'Synthetic category' not in exported.text
                else:
                    assert snapshot['ledger_id'] == ledger_id
                    assert len(snapshot['transactions']) == 1
                    assert snapshot['transactions'][0]['category'] == 'Synthetic category'
        finally:
            # Closing the desktop pipe waits for Uvicorn to finish requests.
            process.stdin.close()
            try:
                assert process.wait(timeout=15) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
