"""Check imported instrumentation against a local OpenTelemetry Collector."""

import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import uuid


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    def log_message(self, *_args):
        pass


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gemfile", type=Path, default=here / "Gemfile")
    gemfile = parser.parse_args().gemfile.resolve()
    name = f"beacon-ruby-smoke-{uuid.uuid4().hex[:12]}"
    image = "otel/opentelemetry-collector-contrib@sha256:89107a3a8f4636a396927edf7025bb9614b8da2d92f4cc3f43109e8d115736e2"
    docker = functools.partial(subprocess.run, check=True, capture_output=True, text=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()

    try:
        with tempfile.TemporaryDirectory(prefix="beacon-ruby-smoke-") as directory:
            work = Path(directory)
            (work / "collector.yaml").write_text(
                "receivers:\n  otlp:\n    protocols:\n      http:\n"
                "        endpoint: 0.0.0.0:4318\n"
                "exporters:\n  file:\n    path: /validation/traces.json\n"
                "service:\n  pipelines:\n    traces:\n"
                "      receivers: [otlp]\n      exporters: [file]\n"
            )
            try:
                docker([
                    "docker", "run", "--detach", "--rm", "--pull=never",
                    "--name", name, "--user", f"{os.getuid()}:{os.getgid()}",
                    "--publish", "127.0.0.1::4318", "--volume", f"{work}:/validation",
                    image, "--config=/validation/collector.yaml",
                ])
                address = docker(["docker", "port", name, "4318/tcp"]).stdout.strip()
                port = int(address.rsplit(":", 1)[1])
                deadline = time.monotonic() + 15
                while True:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=1):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Collector did not become ready") from None
                        time.sleep(0.1)

                env = {key: value for key, value in os.environ.items() if not key.startswith("OTEL_")}
                env.update(
                    BUNDLE_GEMFILE=str(gemfile),
                    BEACON_RUBY_SMOKE_URL=f"http://127.0.0.1:{server.server_port}/smoke",
                    OTEL_EXPORTER_OTLP_ENDPOINT=f"http://127.0.0.1:{port}",
                    OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf",
                    OTEL_TRACES_EXPORTER="otlp",
                )
                subprocess.run(
                    ["bundle", "exec", "ruby", str(here / "http_smoke.rb")],
                    cwd=here, env=env, check=True, timeout=60,
                )
                docker(["docker", "stop", "--time=5", name])
                records = [json.loads(line) for line in (work / "traces.json").read_text().splitlines()]
                spans = []
                for record in records:
                    for resource in record.get("resourceSpans", []):
                        attributes = resource["resource"]["attributes"]
                        assert any(
                            attr["key"] == "service.name"
                            and attr["value"].get("stringValue") == "beacon-ruby-import-smoke"
                            for attr in attributes
                        ), "Unexpected service identity"
                        for scope in resource.get("scopeSpans", []):
                            spans.extend((scope["scope"]["name"], span) for span in scope["spans"])
                roots = [span for _, span in spans if span["name"] == "ruby-import-smoke"]
                clients = [
                    span for scope, span in spans
                    if scope == "OpenTelemetry::Instrumentation::Net::HTTP" and span["kind"] == 3
                ]
                assert len(roots) == 1 and len(clients) == 1, "Expected one root and one HTTP client span"
                root, client = roots[0], clients[0]
                assert client["traceId"] == root["traceId"], "Trace correlation failed"
                assert client["parentSpanId"] == root["spanId"], "Parent correlation failed"
                assert client["kind"] == 3, "Expected a client span"
                print("Collector received the service identity and correlated root/client spans.")
            finally:
                subprocess.run(["docker", "rm", "--force", name], capture_output=True, check=False)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


if __name__ == "__main__":
    main()
