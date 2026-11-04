"""Verify Security logs over HTTP/protobuf through an actual local Collector."""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid


def main():
    root = Path(__file__).resolve().parents[1]
    name = f"beacon-ruby-security-{uuid.uuid4().hex[:12]}"
    image = "otel/opentelemetry-collector-contrib@sha256:89107a3a8f4636a396927edf7025bb9614b8da2d92f4cc3f43109e8d115736e2"
    with tempfile.TemporaryDirectory(prefix="beacon-ruby-security-") as directory:
        work = Path(directory)
        (work / "collector.yaml").write_text(
            "receivers:\n  otlp:\n    protocols:\n      http:\n"
            "        endpoint: 0.0.0.0:4318\n"
            "exporters:\n  file:\n    path: /validation/logs.json\n"
            "service:\n  pipelines:\n    logs:\n"
            "      receivers: [otlp]\n      exporters: [file]\n"
        )
        try:
            subprocess.run([
                "docker", "run", "--detach", "--rm", "--pull=never", "--name", name,
                "--user", f"{os.getuid()}:{os.getgid()}", "--publish", "127.0.0.1::4318",
                "--volume", f"{work}:/validation", image, "--config=/validation/collector.yaml",
            ], check=True, capture_output=True)
            port = int(subprocess.check_output(["docker", "port", name, "4318/tcp"], text=True).strip().rsplit(":", 1)[1])
            deadline = time.monotonic() + 15
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Collector did not become ready") from None
                    time.sleep(0.1)
            env = {key: value for key, value in os.environ.items() if not key.startswith(("OTEL_", "BEACON_SECURITY_"))}
            env.update(BEACON_SECURITY_ENABLED="true", OTEL_LOGS_EXPORTER="otlp",
                       OTEL_EXPORTER_OTLP_ENDPOINT=f"http://127.0.0.1:{port}", OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf")
            subprocess.run(["bundle", "exec", "ruby", "examples/rack_observation.rb"], cwd=root, env=env, check=True, timeout=30)
            subprocess.run(["docker", "stop", "--time=5", name], check=True, capture_output=True)
            bodies = []
            for line in (work / "logs.json").read_text().splitlines():
                for resource in json.loads(line).get("resourceLogs", []):
                    attrs = {a["key"]: a["value"].get("stringValue") for a in resource["resource"]["attributes"]}
                    assert attrs["service.name"] == "beacon-ruby-security-example"
                    for scope in resource.get("scopeLogs", []):
                        assert scope["scope"]["name"] == "io.beacon.security"
                        for record in scope["logRecords"]:
                            body = json.loads(record["body"]["stringValue"])
                            assert record["severityNumber"] == 9
                            assert record["eventName"] == body["event_name"]
                            assert body["schema_version"] == 2
                            attrs = {a["key"]: a["value"].get("stringValue") for a in record["attributes"]}
                            assert attrs["event.name"] == body["event_name"]
                            assert attrs["source"] == body["source"]
                            if body["event_name"] == "beacon.security.finding":
                                assert body["rule"] == "path_traversal"
                                assert body["trace_id"] == record["traceId"]
                                assert body["server_span_id"] == record["spanId"]
                                assert "/dev/null" not in json.dumps(body)
                            bodies.append(body)
            assert any(b["event_name"] == "beacon.security.finding" for b in bodies)
            assert any(b["event_name"] == "beacon.security.sbom.inventory" for b in bodies)
            print(f"Collector received {len(bodies)} Security records with resource, scope, and trace correlation.")
        finally:
            subprocess.run(["docker", "rm", "--force", name], capture_output=True, check=False)


if __name__ == "__main__":
    main()
