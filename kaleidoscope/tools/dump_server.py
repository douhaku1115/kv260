# -*- coding: utf-8 -*-
"""参照実装から取り出した画像とデータを受け取って保存する小さなサーバ。

ブラウザの複数ダウンロードはブロックされることがあるので、
POST で受け取って ref/dump/ に書く。

  使い方:  python tools/dump_server.py [ポート]
  受け口:  POST http://127.0.0.1:8733/<ファイル名>
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ref", "dump")
OUT = os.path.normpath(OUT)


class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        name = os.path.basename(self.path.lstrip("/")) or "dump.bin"
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        print("saved %s (%d bytes)" % (name, len(data)))
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8733
    print("待ち受け 127.0.0.1:%d  保存先 %s" % (port, OUT))
    HTTPServer(("127.0.0.1", port), H).serve_forever()
