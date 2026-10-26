# Ruby Source Import Acceptance

This record covers local acceptance on 2026-10-26 of the
[initial upstream baseline](../UPSTREAM.md). It does not describe a Beacon release.

## Environment and Scope

| Item | Validated value |
| --- | --- |
| Host | Ubuntu 24.04, Linux x86_64 |
| Runtime | CRuby 3.3.12; Bundler 2.5.22 |
| Instrumentation base | Imported source, version 0.27.0 |
| Net::HTTP instrumentation | Imported source, version 0.29.2 |
| API / SDK | 1.11.1 / 1.13.1 |
| OTLP trace exporter | 0.37.0 |
| Receiver | OpenTelemetry Collector Contrib 0.135.0 |
| Transport | OTLP HTTP/protobuf to a local receiver |

Ruby was built in a dedicated user directory from
[official Ruby 3.3.12 source](https://www.ruby-lang.org/en/news/2026/07/16/ruby-3-3-12-released/).
The source archive SHA-256 was checked against the official release record before
building. The [Gemfile](Gemfile) and [Bundler lockfile](Gemfile.lock) pin the smoke
check dependencies; the lockfile is intentionally tracked for this consumer.
Other platforms listed in that lockfile have not been validated.

## Component Tests

| Check | Result |
| --- | --- |
| Shared base | 51 runs, 68 assertions; no failures, errors, or skips; 97.35% line coverage |
| Net::HTTP `dup` | 67 runs, 155 assertions; no failures or errors; 41 skips |
| Net::HTTP `stable` | 67 runs, 109 assertions; no failures or errors; 41 skips |
| Net::HTTP `old` | 67 runs, 98 assertions; no failures or errors; 44 skips |
| Net::HTTP combined | 100% line coverage across the three modes |

Net::HTTP loads all mode-specific test files in each run; tests for the other modes
are intentionally skipped. Running only the default `rake test` would not exercise
these mode-specific cases. From the repository root, run:

```sh
(cd instrumentation/base && bundle install && bundle exec rake test)
(cd instrumentation/net_http && bundle install && bundle exec appraisal install && bundle exec appraisal rake test)
```

The initial `dup` run failed its connection-error case after waiting on the external
`invalid.com` host. The same case exists in all three modes. These tests now inject
a `SocketError` at socket creation and explicitly assert its type while retaining
the error-span assertions. This removes external DNS and network dependence without
changing runtime instrumentation.

## Actual Receiver Check

The [Ruby smoke program](http_smoke.rb) makes an instrumented HTTP request within
a parent span. The [Python harness](collector_smoke.py) starts a temporary local
HTTP server and a Collector container, runs the Ruby program, and reads the
Collector's exported trace records. It verifies the service identity, HTTP client
span kind, shared trace ID, and parent span ID. Temporary servers, containers, and
trace output are removed after the run.

Requirements are Python 3, Docker, and the Collector 0.135.0 image. The harness pins
the image digest and uses `--pull=never`; download the image before running it if
it is not already present. From the repository root:

```sh
docker pull otel/opentelemetry-collector-contrib:0.135.0
cd beacon/validation
bundle install
BUNDLE_FROZEN=true python3 collector_smoke.py
```

The source-based check passed: the Collector received the expected service identity
and correlated root and HTTP client spans. The harness also accepts `--gemfile` to
check installed component artifacts with a separate dependency definition.

## Artifact and Repository Checks

The base and Net::HTTP upstream component gems were built locally. They retain their
upstream package identities and are not Beacon releases. These build commands run
from the repository root:

```sh
(cd instrumentation/base && mkdir -p pkg && gem build opentelemetry-instrumentation-base.gemspec --output pkg/opentelemetry-instrumentation-base-0.27.0.gem)
(cd instrumentation/net_http && mkdir -p pkg && gem build opentelemetry-instrumentation-net_http.gemspec --output pkg/opentelemetry-instrumentation-net_http-0.29.2.gem)
```

For isolated installation, the two built gems and the cached smoke-check dependency
gems were installed into an empty gem home. A separate Gemfile used exact component
versions without local source paths. Bundler resolved and checked the installed
dependency graph offline before the Collector harness ran successfully against those
artifacts.

Repository checks use the upstream local-link configuration, plus a separate check
of relative links in the new documentation:

```sh
bundle install
npm ci --ignore-scripts
PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome lsconfig='-c .github/.linkspector-local_check.yml' bundle exec npm run check
```

The full command initially stopped while fetching remote CSpell dictionaries.
The two dictionaries are now pinned npm development dependencies and are loaded
locally, so checks no longer download dictionary configuration from a CDN.
With these pins, the complete repository check command passed. Existing
informational method-documentation notices remain in upstream code; they are not
failing checks.

## Limits

This acceptance covers the shared base, Net::HTTP modes, and the local Collector
trace path on the environment above. It does not validate Rails, other client or
framework integrations, JRuby, other operating systems or Ruby versions, DataKit,
Metrics, Logs, Profiling, or Security. These checks do not publish a gem, establish
an official installation entry, or create a release.
