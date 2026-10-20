"""HTTP API on 127.0.0.1 with SSE streaming.

GET  /status                    devices, boost availability + reason
POST /chat                      {message, session?, device: npu|cpu, save?: true, image?: {data, mime}} -> SSE
GET  /history                   session list
GET  /history/<id>              messages of a session
DELETE /history/<id>
POST /history                   {messages: [{role, content, device?}]} -> {session}   (import a launcher answer)
POST /cpu/unload                drop the boost now

SSE events: session {id} | status {state} | token {t} | error {code, message}
  | done {tokens, tps, ttft, device, ctx, ctx_max, kept, trimmed}: ctx = prompt tokens of ctx_max, kept = how many of
    the last history messages (this question included) fit, older ones were dropped; trimmed = earlier answers were
    cut to their beginning to fit. Each request is built from its own
    session's history, so chats don't affect each other.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import config, store, sysmon, vision
from .engines import CpuEngine, NpuEngine, Unavailable


class App:
    def __init__(self, cfg):
        self.cfg = cfg
        os.makedirs(config.DATA_DIR, exist_ok=True)
        self.store = store.Store(os.path.join(config.DATA_DIR, "history.db"))
        self.npu = NpuEngine(cfg)
        self.cpu = CpuEngine(cfg)
        threading.Thread(target=self._monitor, daemon=True).start()

    def _monitor(self):
        while True:
            time.sleep(2)
            try:
                self.cpu.tick()
            except Exception as e:
                print(f"monitor: {e}", flush=True)

    def status(self):
        ok, code, why = self.cpu.availability()
        warm_left = 0
        if self.cpu.state == "ready" and not self.cpu.busy:
            warm_left = max(0, int(self.cfg["cpu_keep_warm_min"] * 60 - (time.time() - self.cpu.last_used)))
        return {
            "npu": {"state": self.npu.state, "busy": self.npu.busy, "error": self.npu.error},
            "cpu": {"state": self.cpu.state, "busy": self.cpu.busy, "available": ok, "reason": code,
                    "message": why, "warm_left_s": warm_left, "last_unload": self.cpu.last_unload},
            "mem_available_gb": round(sysmon.mem_available_gb(), 1),
            "cpu_psi_avg10": sysmon.cpu_psi_avg10(),
            "load_ratio": round(sysmon.load_ratio(), 2),
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    app = None

    def log_message(self, fmt, *args):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        p = self.path.rstrip("/")
        if p == "/status":
            return self._json(self.app.status())
        if p == "/history":
            return self._json(self.app.store.sessions())
        if p.startswith("/history/"):
            sid = p.split("/")[2]
            if not self.app.store.exists(sid):
                return self._json({"error": "not found"}, 404)
            return self._json(self.app.store.messages(sid))
        self._json({"error": "not found"}, 404)

    def do_DELETE(self):
        p = self.path.rstrip("/")
        if p.startswith("/history/"):
            self.app.store.delete(p.split("/")[2])
            return self._json({"ok": True})
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        p = self.path.rstrip("/")
        try:
            req = self._body()
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        if p == "/chat":
            return self._chat(req)
        if p == "/history":
            msgs = [m for m in req.get("messages", []) if m.get("role") in ("user", "assistant") and m.get("content")]
            if not msgs:
                return self._json({"error": "no messages"}, 400)
            sid = self.app.store.create(msgs[0]["content"])
            for m in msgs:
                self.app.store.add(sid, m["role"], m["content"], m.get("device"))
            return self._json({"session": sid})
        if p == "/cpu/unload":
            self.app.cpu.unload("manual")
            return self._json({"ok": True})
        self._json({"error": "not found"}, 404)

    def _chat(self, req):
        app = self.app
        text = (req.get("message") or "").strip()
        device = req.get("device", "npu")
        save = req.get("save", True)
        sid = req.get("session")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        gone = []

        def emit(event, data):
            if gone:
                return
            try:
                self.wfile.write(f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode())
                self.wfile.flush()
            except OSError:
                gone.append(1)   # client went away: cancel the generation

        if req.get("image"):
            try:
                text = vision.describe(req["image"].get("data"), req["image"].get("mime"), text) + "\n\n" + text
            except vision.NotSupported as e:
                return emit("error", {"code": "image_unsupported", "message": str(e)})
        if not text:
            return emit("error", {"code": "empty", "message": "пустой запрос"})
        if device not in ("npu", "cpu"):
            return emit("error", {"code": "bad_device", "message": device})

        history = app.store.messages(sid) if sid and app.store.exists(sid) else []
        history = [{"role": m["role"], "content": m["content"]} for m in history]
        history.append({"role": "user", "content": text})
        if save:
            if not sid or not app.store.exists(sid):
                sid = app.store.create(text)
            app.store.add(sid, "user", text, device)
            emit("session", {"id": sid})

        engine = app.npu if device == "npu" else app.cpu
        parts = []
        try:
            res = engine.generate(history, lambda s: (parts.append(s), emit("token", {"t": s})),
                                  lambda: bool(gone), lambda st: emit("status", {"state": st}))
        except Unavailable as e:
            return emit("error", {"code": e.code, "message": str(e)})
        except Exception as e:
            return emit("error", {"code": "internal", "message": str(e)})
        answer = res.pop("text", None) or "".join(parts)
        res["device"] = device
        if save and answer.strip():
            app.store.add(sid, "assistant", answer.strip(), device, res)
        res["cancelled"] = bool(gone)
        emit("done", res)
        print(f"{device}: {res['tokens']} tok, {res['tps']} tok/s, ttft {res['ttft']}s"
              f"{' (cancelled)' if gone else ''}", flush=True)


def main():
    cfg = config.load()
    lib = cfg["npu_lib_dir"]
    # The patched npu_compiler is picked up by the NPU driver via LD_LIBRARY_PATH, which only works at exec time
    if lib and lib not in os.environ.get("LD_LIBRARY_PATH", "").split(":"):
        env = dict(os.environ, LD_LIBRARY_PATH=":".join(filter(None, [lib, os.environ.get("LD_LIBRARY_PATH")])),
                   ZE_INTEL_NPU_CACHE_SIZE="0")
        os.execve(sys.executable, [sys.executable, "-m", "npu_assistant.server"] + sys.argv[1:], env)
    os.environ.setdefault("ZE_INTEL_NPU_CACHE_SIZE", "0")
    Handler.app = App(cfg)
    srv = ThreadingHTTPServer((cfg["host"], cfg["port"]), Handler)
    srv.daemon_threads = True
    print(f"listening on http://{cfg['host']}:{cfg['port']}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
