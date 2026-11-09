#!/usr/bin/env python3
"""Regression suite for speak_loop's kokoro reachability probe.

BUG-077: a failed probe was cached forever. The only code that reset the cache
lived in kokoro_synth's error path, which cannot run unless kokoro_ready() has
already returned True -- so one timed-out probe at startup pinned the speak
loop to the local robot voice for its whole lifetime, with the daemon healthy
and nothing in any log. These cases pin the shape the cache must have: a True
is trusted, a False EXPIRES, and an outage is reported once.

Run: python3 tests/test-kokoro-probe.py
"""
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "prototype"))
os.environ.setdefault("SPEAKLOOP_SAY_VOICE", "Samantha")   # no `say` on CI

import speak_loop                                          # noqa: E402

PASS = FAIL = 0
HITS = {"health": 0}


def expect(cond, what):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {what}")
    else:
        FAIL += 1
        print(f"  FAIL  {what}")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        HITS["health"] += 1
        body = json.dumps({"ok": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def reset(url, recheck):
    speak_loop.KOKORO_URL = url
    speak_loop.KOKORO_RECHECK_SECS = recheck
    speak_loop._kokoro.update({"up": None, "checked": 0.0, "warned": False})


def main():
    dead = f"http://127.0.0.1:{free_port()}"       # nothing listening: refused

    srv = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    live = f"http://127.0.0.1:{srv.server_address[1]}"

    print("BUG-077: a failed probe must not be permanent")
    reset(dead, 0.0)
    expect(speak_loop.kokoro_ready() is False, "a refused probe reports down")
    speak_loop.KOKORO_URL = live       # daemon comes up, as it always does
    expect(speak_loop.kokoro_ready() is True,
           "once the daemon answers, the engine comes back (THE BUG)")

    print("the cache still has to work -- that was the point of it")
    reset(dead, 30.0)
    expect(speak_loop.kokoro_ready() is False, "down, with a 30s recheck")
    before = HITS["health"]
    speak_loop.KOKORO_URL = live
    expect(speak_loop.kokoro_ready() is False,
           "a fresh False is NOT re-probed inside the window")
    expect(HITS["health"] == before, "...and really sent no request")

    reset(live, 30.0)
    expect(speak_loop.kokoro_ready() is True, "up")
    before = HITS["health"]
    expect(speak_loop.kokoro_ready() is True, "a True is served from cache")
    expect(HITS["health"] == before, "...with no second probe")

    print("a dead daemon mid-run is still caught by the synth path")
    reset(live, 3600.0)
    expect(speak_loop.kokoro_ready() is True, "up")
    speak_loop._kokoro["up"] = None            # what kokoro_synth does on error
    speak_loop.KOKORO_URL = dead
    expect(speak_loop.kokoro_ready() is False,
           "None re-probes at once, ignoring the recheck window")

    print("an outage is reported, once")
    reset(dead, 0.0)
    speak_loop.kokoro_ready()
    expect(speak_loop._kokoro["warned"] is True, "the first failure warns")
    speak_loop.KOKORO_URL = live
    speak_loop.kokoro_ready()
    expect(speak_loop._kokoro["warned"] is False, "recovery clears the warning")

    srv.shutdown()
    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
