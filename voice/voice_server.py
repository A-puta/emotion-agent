"""常驻语音服务：模型只加载一次，之后按请求出音频。

启动：
  python voice_server.py            # 监听 127.0.0.1:18080

用法（PowerShell）：
  $r = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:18080/say `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes('{"text":"你好呀","name":"测试"}'))
  $r.path

健康检查：
  Invoke-RestMethod http://127.0.0.1:18080/health
"""
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, r"D:\DSH-资料\voice")
import render

HOST, PORT = "127.0.0.1", 18080
_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self._json(200, {"ok": True, "model": render.F5 is not None})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/say"):
            self._json(404, {"error": "not found"})
            return
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception as e:
            self._json(400, {"error": f"bad json: {e}"})
            return
        text = (req.get("text") or "").strip()
        if not text:
            self._json(400, {"error": "empty text"})
            return
        name = req.get("name") or "回复"
        ref = req.get("ref") or "尾端"
        speed = float(req.get("speed") or 1.0)
        try:
            with _lock:
                w, d, dur, breaths, el = render.render(text, name, ref, speed)
            self._json(200, {"path": d, "seconds": dur, "breaths": breaths, "elapsed": el})
        except Exception as e:
            self._json(500, {"error": f"{type(e).__name__}: {e}"})


def main():
    print("loading model...", flush=True)
    render.get_model()
    print(f"ready on http://{HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
