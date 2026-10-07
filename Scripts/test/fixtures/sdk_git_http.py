#!/usr/bin/env python3
"""Loopback Git HTTP/API fixture; never contacts an external service."""
import base64
import http.server
import json
import os
import subprocess
import sys
import urllib.parse

origin, ready, events, mode = sys.argv[1:]
expected = "Basic " + base64.b64encode(b"x-access-token:fixture-token").decode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        path = urllib.parse.urlsplit(self.path)
        authorization = self.headers.get("Authorization", "")
        with open(events, "a", encoding="utf-8") as log:
            log.write(json.dumps({"path": path.path, "auth": authorization}) + "\n")
        if path.path.startswith("/repos/fixture/sdk/compare/"):
            if mode == "api-deny" or authorization != "Bearer fixture-token":
                self.send_response(401)
                self.end_headers()
                return
            status = "identical" if "/maint/fixture..." in path.path else "ahead"
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({"status": status}).encode())
            return
        if mode == "deny" or authorization != expected:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="synthetic SDK"')
            self.end_headers()
            return
        environment = os.environ.copy()
        environment.update({
            "GIT_PROJECT_ROOT": os.path.dirname(origin),
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": "/" + os.path.basename(origin) + path.path.removeprefix("/fixture/sdk.git"),
            "QUERY_STRING": path.query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": self.headers.get("Content-Length", "0"),
        })
        body = self.rfile.read(int(environment["CONTENT_LENGTH"]))
        response = subprocess.run(["git", "http-backend"], input=body, env=environment,
                                  stdout=subprocess.PIPE, check=True).stdout
        header, data = response.split(b"\r\n\r\n", 1)
        self.send_response(200)
        for line in header.decode().splitlines():
            key, value = line.split(":", 1)
            self.send_header(key, value.strip())
        self.end_headers()
        self.wfile.write(data)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(ready, "w", encoding="utf-8") as file:
    file.write(str(server.server_port))
server.serve_forever()
