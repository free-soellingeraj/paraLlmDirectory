#!/usr/bin/env python3
"""kokoro-daemon.py — one local neural TTS service for the whole workspace.

Why a daemon at all: the `kokoro` CLI reloads the 82M model on every
invocation, which measured 48-88s for a five-second sentence. The model load is
the cost, not the synthesis, so it has to be paid once and shared. One service
serves every pane; a pane picks its voice per request, which is free because the
54 voices are style embeddings in a separate file rather than separate models.

Why ONNX rather than the torch package that was already installed: torch on
this machine managed 0.3x realtime even with the model resident — unusable at
any level of persistence. ONNX fp16 on the plain CPU provider is the fastest
configuration measured here; CoreML was erratic on this model (0.4-1.0x, with
constant-folding warnings suggesting provider thrash), so it is available but
not the default.

Protocol, deliberately boring so a shell can drive it too:
    GET  /health            -> {"ok":true,"voices":[...],"provider":"..."}
    POST /synth             <- {"text":"...","voice":"am_michael","speed":1.25}
                            -> audio/wav bytes

Run:  kokoro-daemon.py [--port 8788] [--model-dir ~/.cache/kokoro-onnx]
"""
from __future__ import annotations

import argparse
import io
import json
import os
import socket
import sys
import threading
import warnings
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

warnings.filterwarnings("ignore")
# onnxruntime prints a wall of "Could not find a CPU kernel ... constant fold"
# warnings for this model. They are harmless and they drown the log.
os.environ.setdefault("ORT_LOGGING_LEVEL", "3")
os.environ.setdefault("ESPEAK_DATA_PATH", "/opt/homebrew/share/espeak-ng-data")

DEFAULT_PORT = int(os.environ.get("KOKORO_PORT", "8788"))
DEFAULT_DIR = os.path.expanduser(
    os.environ.get("KOKORO_MODEL_DIR", "~/.cache/kokoro-onnx"))
DEFAULT_MODEL = os.environ.get("KOKORO_MODEL", "kokoro-v1.0.fp16.onnx")
DEFAULT_PROVIDER = os.environ.get("KOKORO_PROVIDER", "CPUExecutionProvider")
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "am_michael")

_state: dict = {"kokoro": None, "voices": [], "provider": DEFAULT_PROVIDER}
# I assumed concurrent calls would contend (the intra-op pool already uses every
# core) and shipped this serialised. Measured, that was wrong — aggregate
# throughput against this daemon, same text, same voice:
#   1 worker  0.74x realtime
#   2 workers 1.13x
#   3 workers 1.66x
# Narration needs sustained >1.0x to keep up with playback, so serialising put
# it UNDER the line and three workers put it over. Default 3, matching
# SYNTH_WORKERS in speak_loop.
_lock = threading.Semaphore(int(os.environ.get("KOKORO_CONCURRENCY", "3")))


def load(model_dir: str, model: str, provider: str) -> None:
    import onnxruntime as ort
    from kokoro_onnx import Kokoro

    model_path = os.path.join(model_dir, model)
    voices_path = os.path.join(model_dir, "voices-v1.0.bin")
    for p in (model_path, voices_path):
        if not os.path.exists(p):
            sys.exit(f"missing {p}\n"
                     "Fetch the model files with:\n"
                     "  mkdir -p ~/.cache/kokoro-onnx && cd ~/.cache/kokoro-onnx\n"
                     "  B=https://github.com/thewh1teagle/kokoro-onnx/releases/"
                     "download/model-files-v1.1\n"
                     "  curl -LO $B/kokoro-v1.0.fp16.onnx && curl -LO $B/voices-v1.0.bin")

    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    sess = ort.InferenceSession(model_path, sess_options=opts, providers=[provider])
    _state["kokoro"] = Kokoro.from_session(sess, voices_path)
    with zipfile.ZipFile(voices_path) as z:
        _state["voices"] = sorted(n[:-4] for n in z.namelist() if n.endswith(".npy"))
    _state["provider"] = provider


def synth_wav(text: str, voice: str, speed: float) -> bytes:
    import soundfile as sf

    with _lock:
        audio, sr = _state["kokoro"].create(text, voice=voice, speed=speed,
                                            lang="en-us")
    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV")
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):            # the daemon's stdout is a log file
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") != "/health":
            return self._send(404, b"not found", "text/plain")
        body = json.dumps({"ok": _state["kokoro"] is not None,
                           "provider": _state["provider"],
                           "voices": _state["voices"]}).encode()
        self._send(200, body, "application/json")

    def do_POST(self):
        if self.path.rstrip("/") != "/synth":
            return self._send(404, b"not found", "text/plain")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            if not text:
                # Nothing to say is not an error, but there is no audio either.
                return self._send(400, b"empty text", "text/plain")
            voice = req.get("voice") or DEFAULT_VOICE
            if voice not in _state["voices"]:
                return self._send(
                    400, f"unknown voice {voice}".encode(), "text/plain")
            wav = synth_wav(text, voice, float(req.get("speed") or 1.0))
            self._send(200, wav, "audio/wav")
        except Exception as e:                       # keep the daemon alive
            self._send(500, f"{type(e).__name__}: {e}".encode(), "text/plain")


def port_busy(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--model-dir", default=DEFAULT_DIR)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--provider", default=DEFAULT_PROVIDER)
    args = ap.parse_args()

    # One service per machine. A second start is a no-op rather than a port
    # clash, so every pane's toggle can just try to start it.
    if port_busy(args.port):
        print(f"kokoro-daemon already listening on {args.port}", flush=True)
        return

    import time
    t0 = time.time()
    load(args.model_dir, args.model, args.provider)
    print(f"loaded {args.model} on {args.provider} in {time.time()-t0:.2f}s; "
          f"{len(_state['voices'])} voices; listening on 127.0.0.1:{args.port}",
          flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
