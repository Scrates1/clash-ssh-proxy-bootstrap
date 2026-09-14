"""Local HTTPS health endpoint and rejecting/working proxies for curl tests."""

import base64
import http.server
import json
import pathlib
import re
import select
import socket
import ssl
import sys
import threading

fixture_root = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])


def log(name):
    with (fixture_root / name).open("a") as output:
        output.write("request\n")


class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log("health.log")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


class Proxy(http.server.BaseHTTPRequestHandler):
    def do_CONNECT(self):
        log("good-proxy.log" if self.server.forward else "bad-proxy.log")
        if not self.server.forward:
            self.send_error(502)
            return
        with socket.create_connection(("127.0.0.1", health.server_port), timeout=5) as upstream:
            self.send_response(200)
            self.end_headers()
            sockets = [self.connection, upstream]
            while True:
                readable, _, _ = select.select(sockets, [], [], 5)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is self.connection else self.connection).sendall(data)

    def log_message(self, *_):
        pass


health = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(fixture_root / "cert.pem", fixture_root / "key.pem")
health.socket = tls.wrap_socket(health.socket, server_side=True)
bad_proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
bad_proxy.forward = False
good_proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
good_proxy.forward = True
for server in [health, bad_proxy, good_proxy]:
    threading.Thread(target=server.serve_forever, daemon=True).start()

# Exercise the actual manager's POSIX probe and cleanup bodies on Linux.
remote_source = (repo_root / "src/manager/Remote.ps1").read_text()
probe_section = remote_source.split("function Invoke-RemoteProxyProbe", 1)[1]
probe = re.search(r"\$command = @'\n(.*?)\n'@\.Replace", probe_section, re.S).group(1)
for name, port in [("bad", bad_proxy.server_port), ("good", good_proxy.server_port)]:
    (fixture_root / f"manager-{name}.sh").write_text(probe.replace("__PROXY_URL__", f"'http://127.0.0.1:{port}'"))

cleanup_source = (repo_root / "src/manager/Operations.ps1").read_text()
cleanup_section = cleanup_source.split("function Remove-TargetRemoteArtifacts", 1)[1]
cleanup = re.search(r"\$remoteCommand = @'\n(.*?)\n'@\.Replace", cleanup_section, re.S).group(1)
encoded_key = base64.b64encode(b"ssh-ed25519 QUJDRA==").decode()
(fixture_root / "cleanup.sh").write_text(cleanup.replace("__ENCODED_KEY__", f"'{encoded_key}'"))
(fixture_root / "ports.json").write_text(json.dumps({"health": health.server_port, "bad": bad_proxy.server_port, "good": good_proxy.server_port}))
threading.Event().wait()
