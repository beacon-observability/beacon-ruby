# Beacon Security for Ruby

An opt-in runtime observation gem for Linux CRuby 3.3+, developed independently of
upstream OpenTelemetry instrumentation. This source addition is unreleased and is
not included in Beacon Ruby v1.0.0.

The implementation pins [Beacon Security specification](https://github.com/beacon-observability/beacon-security-spec)
commit `af1b834501210bfd197bf606163680129cc5d09b`, emits **schema v2**, and implements
**fingerprint v1**. The same versions are recorded in the packaged
[contract.json](contract.json) and Ruby constants. All four pinned fingerprint
vectors are checked by the tests. V1 events and legacy `SECURITY_*` settings are
not supported.

## Install and start

Add the gem from this source checkout to your application's Gemfile. The host
application supplies Rack and the OpenTelemetry SDK and exporters:

```ruby
gem 'beacon-security', path: '/path/to/beacon-ruby/security'
gem 'opentelemetry-sdk'
gem 'opentelemetry-logs-sdk'
gem 'opentelemetry-exporter-otlp-logs'
```

Load optional clients before starting Security so their entry points can be
installed. For a plain Rack application:

```ruby
require 'rack'
require 'net/http'
# require 'pg'
# require 'mysql2'
require 'opentelemetry/sdk'
require 'opentelemetry/sdk/logs'
require 'opentelemetry-exporter-otlp-logs'
require 'beacon/security'

OpenTelemetry::SDK.configure
security = Beacon::Security.start
use Beacon::Security::Middleware, runtime: security
run MyApplication
```

Set `BEACON_SECURITY_ENABLED=true`. Configure Logs using `OTEL_LOGS_EXPORTER`,
`OTEL_EXPORTER_OTLP_*`, TLS/authentication and resource settings from the host's
OpenTelemetry installation. Security creates no second exporter or service-name
configuration. With no configured logger provider, the API is a no-op; API calls
are not evidence of Collector or backend receipt.

Place Security middleware **inside** the OTel Rack server-span middleware to
capture the server trace context. Framework adapters may set
`env['beacon.security.route']` to a static route template; raw request URLs and
paths are never exported as route context. The default service fallback for
internal fingerprints is `unknown_service:ruby`. When the host uses different
resource construction, pass `resource: resource.attribute_enumerator.to_h` to
`Beacon::Security.start` using the same resource as its providers.

Start once per worker **after fork**. An inherited runtime disables itself by
PID; call `Beacon::Security.start` in each child. On application shutdown call
`security.force_flush`, `security.shutdown`, then flush/shut down the host's
OpenTelemetry providers. The Security flush waits at most one second for its own
queue, not for transport acknowledgement. Shutdown waits at most one second for
each of its two workers. A host exporter that never returns can leave its worker
alive until process exit. Stop does not undo Ruby prepends; without an active
request their observation calls have no effect.

## Configuration

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `BEACON_SECURITY_ENABLED` | `false` | Enable runtime and middleware collection. |
| `BEACON_SECURITY_SBOM_ENABLED` | `true` | Collect dependencies while Security is enabled. |
| `BEACON_SECURITY_SBOM_REFRESH_SECONDS` | `300` | Delay after each collection finishes; positive integer. Invalid/zero values use 300. |
| `BEACON_SECURITY_LOCAL_OUTPUT_ENABLED` | `false` | Opt in to diagnostic files. |
| `BEACON_SECURITY_OUTPUT` | `beacon-security-output` | Directory for the last emitted JSON record per source and instance. |
| `BEACON_SECURITY_EVIDENCE_FILE` | unset | Optional JSONL findings file, only when local output is enabled. |

Boolean settings accept case-insensitive `true`; other explicit values are false.
Security alone never enables disk output. New diagnostic directories/files use
0700/0600 permissions. Files are process-local debugging aids, not durable
aggregation, complete multipart inventories, or delivery acknowledgements.

## Modeled coverage

| Input / sink | Coverage |
| --- | --- |
| Sources | Rack flat decoded query values and `HTTP_*` header values, except authorization, proxy authorization and cookies. |
| SQL | `PG::Connection#exec`, `#exec_params`, `#prepare`; `Mysql2::Client#query`, `#prepare`. Only templates are matched; bound values and prepared execution are excluded. |
| Commands | `Kernel#system`, `#spawn`, and module equivalents. A single string uses `shell_script` / `command_injection`; separate executable/argument strings use `command_execution`. |
| Files | `File.read`, `binread`, `write`, `binwrite`, `delete`, `unlink`; read paths are sources, other paths are targets. |
| HTTP | `Net::HTTP#request`: destination address (`ssrf`) and path/query (`http_request_input`). |

Client hooks use isolated, idempotent Ruby prepends because these libraries do
not expose a shared before-invocation callback. Clients loaded after startup
require another explicit `Beacon::Security::Hooks.install` call. The original
return values, keyword arguments, blocks, and application exceptions are preserved.
`Kernel.system`/`spawn` remain public module methods and private instance methods.

Matching is bounded **substring correlation**, not character-level taint tracking.
Equal unrelated strings can match; transformations can lose matches. No sanitizer,
SQL dialect, shell grammar, destination policy or exploit-success analysis is
implemented. Every classification is `unknown`, with reason
`approximate_flow_without_policy`; invocation attempts are not confirmed attacks.
Request-level finding IDs deduplicate repeated observations at a stable code
location. Different requests receive different occurrence IDs. No propagation,
range, stack, component, or sampled-out interval support is claimed.

Coverage gaps include body/multipart capture, recursive parameters, async/thread
propagation, streamed response bodies, native extensions, other database aliases,
`File.open`/IO/Pathname, backticks/exec/Process.spawn, Rails-specific adapters,
DNS resolution policy, and other HTTP clients. Findings set
`collection_complete=false` and describe the approximate precision and gaps.
Request input is never read from `rack.input`, and original values, SQL text,
shell scripts, file arguments and request header values are never included in
findings. Source names are structural query/header keys; application-owned route
metadata must contain templates only.

## Budgets and delivery

Each request retains at most 64 sources, 4096 bytes per source, 65,536 aggregate
source bytes, 128 finding fingerprints, and 1024 sink observations. Queries and sink values over 65,536
bytes are not analyzed. Source names are limited to 256 bytes. Stack lookup is
limited to 64 frames and skips Security, Ruby library and installed gem paths.
Budget exhaustion declares real truncation on retained findings; if no finding
remains, no separate diagnostic event is emitted.

A shared 1024-record queue hands findings and inventories to a background worker
without blocking the application. Full queues drop new records. A record has a
65,536-byte export limit. Oversized findings omit optional evidence and declare
truncation; a still-oversized record is dropped. No health, loss, replacement,
summary or replay event families are exported. Host OTel queues and network
configuration also affect best-effort delivery.

Logs use scope `io.beacon.security`, gem version, INFO/9 severity, native event
name, `event.name`/`source` attributes and JSON string bodies. Available trace
context is preserved in both the finding body and the OTel record. An identical
current/server span ID is omitted from the body. Resource metadata remains on
OpenTelemetry resources.

## Runtime dependencies

Security asynchronously publishes `beacon.security.sbom.inventory` immediately,
then serially after each configured delay even when dependencies are unchanged.
It observes `Gem.loaded_specs`: activated Ruby gems, not every build dependency,
required file, native library or reachable component. Entries contain real names
and versions; no synthetic artifact hashes are emitted. Scans exceeding 10,000
gems or failing timing/collection emit nothing. A valid empty list clears the
previous list. Large inventories have zero-based parts with shared timestamps and
instance metadata; consumers must assemble every part before replacing inventory.

Linux `/proc/self/stat` process-start ticks and `CLOCK_BOOTTIME` provide process
start and uptime independently of gem/framework initialization. `started_at` is
fixed after first observation, uptime is monotonic and `observed_at` strictly
increases per producer. Unsupported timing platforms emit no inventory. Other
operating systems, JRuby and containers without readable procfs are not validated.

## Verification

From this directory:

```sh
bundle install
bundle exec rake test
bundle exec appraisal install
bundle exec appraisal rake test
bundle exec rake yard
gem build beacon-security.gemspec --output pkg/beacon-security-0.1.0.gem
BEACON_SECURITY_ENABLED=true bundle exec ruby examples/rack_observation.rb
python3 test/collector_smoke.py
```

Create `pkg/` before building. Tests optionally use disposable PostgreSQL/MySQL
services with password `beacon-local-test`, a MySQL `security_test` database and
loopback-published ports `BEACON_TEST_PG_PORT` / `BEACON_TEST_MYSQL_PORT`; absent
ports skip those two integration tests. MySQL's native gem needs client development
headers/libraries. The Collector check requires Docker and the cached 0.135.0
image pinned by digest in the harness. It verifies actual HTTP/protobuf Logs
receipt, resource identity, scope, finding/SBOM events and trace correlation.

See [acceptance](ACCEPTANCE.md) for measured evidence and limitations. No backend
vulnerability confirmation, DataKit acceptance or production support matrix is
established by these tests.
