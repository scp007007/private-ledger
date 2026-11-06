"""Run the desktop-owned service; closing its input requests a graceful stop."""

import argparse
import sys
import threading

import uvicorn


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    server = uvicorn.Server(uvicorn.Config(
        'app.main:app', host=args.host, port=args.port, access_log=False,
        use_colors=False, timeout_graceful_shutdown=10,
    ))

    def wait_for_desktop():
        # No credentials travel over stdin. EOF also stops an orphaned service.
        sys.stdin.readline()
        server.should_exit = True

    threading.Thread(target=wait_for_desktop, daemon=True).start()
    server.run()


if __name__ == '__main__':
    main()
