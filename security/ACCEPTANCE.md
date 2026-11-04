# Security source acceptance

Local verification on 2026-11-04 used Ubuntu 24.04 x86_64, isolated CRuby 3.3.12 and
Bundler 2.5.22 at `/home/liurui/.local/share/beacon-ruby/ruby-3.3.12/bin`.
This is source-development evidence, not a published Beacon Ruby release.

## Contract and runtime tests

The pinned specification commit, schema version and fingerprint version appear
in [contract.json](contract.json). Tests use copies of that commit's v2 JSON
Schema and all four fingerprint vectors. Ruby's JSON parser rejects lone Unicode
surrogate escapes; the vector reader replaces those escapes with U+FFFD before
parsing, and a separate test exercises malformed UTF-16 input normalization.

The current suite has 22 tests and 133 assertions with no failures, errors or
skips; a clean coverage run measured 95.48% line coverage. The suite and its
`current` Appraisal both pass with PostgreSQL 16.15 and
MySQL 8.4 in disposable loopback-only Docker containers. Database tests establish
that actual bound parameters do not become SQL template findings, while actual
request input embedded in templates does. Additional checks cover real File,
Kernel and Net::HTTP calls, method visibility, exceptions, request deduplication,
fiber/thread isolation, API-only startup without the Logs SDK, OTel scope/resource
and trace mapping, exporter failure, queue saturation, source/sink budgets,
inventory schema, multipart completeness and byte limits, diagnostic permissions,
and repeated unchanged periodic inventories.

Run the commands from [README](README.md). PostgreSQL/MySQL ports are discovered
with `docker port`; they are never taken from existing application databases.
Local MySQL compilation used Ubuntu's `libmariadb-dev`, `libmariadb-dev-compat`
and `libmariadb3` packages extracted to `/tmp/beacon-ruby-mariadb/root`, without
changing global library paths. The installed gem needs
`MARIADB_PLUGIN_DIR=/tmp/beacon-ruby-mariadb/root/usr/lib/x86_64-linux-gnu/libmariadb3/plugin`
for that temporary client installation. A normal system development package
installation does not need this override. `Gemfile.lock` pins the tested graph.

## Collector and package

`python3 test/collector_smoke.py` passed against the cached Collector Contrib
0.135.0 image pinned by digest in the harness. The actual receiver obtained a
finding and dependency inventories over OTLP HTTP/protobuf. The check verifies
service resource identity, Security scope, INFO severity, event/source attributes,
schema version, native/body trace correlation and absence of raw file input.
Initial and explicit collections may both publish an inventory, as required by
the periodic-publication contract.

`gem build beacon-security.gemspec` succeeds. The gem was installed into a new
temporary gem home, resolved without a source path, and passed the same Collector
check. The packaged contract and Ruby version constants expose provenance. YARD
documentation generation succeeds. Temporary Collector containers and output are
removed by the harness even on failure.

## Performance evidence

The reproducible `bundle exec ruby test/benchmark.rb` benchmark uses 10,000
requests per run and the median of three runs. Observed microseconds per request
on this host:

| Path                                         | Microseconds/request |
| -------------------------------------------- | -------------------: |
| Plain Rack lambda                            |                0.534 |
| Security middleware disabled                 |                0.593 |
| Enabled, one query source, no sensitive call |               21.858 |
| Enabled, one matching SQL observation        |              240.335 |

The enabled matching case includes code-location lookup, fingerprinting, event
construction and the asynchronous producer queue with a no-op OTel provider.
Queue saturation may drop records; these timings are not delivery throughput,
a production overhead guarantee, end-to-end exporter benchmarks, or validation
of large source sets. Production capacity must account for application call
frequency, the documented budgets, and configured OTel queues/exporters.

## Repository checks

From the repository root, the full check passes with the same local-link and
browser setup used by the existing source-import acceptance:

```sh
PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome lsconfig='-c .github/.linkspector-local_check.yml' bundle exec npm run check
```

This covers Ruby lint/format/source checks, Markdown, JSON, spelling and the
repository's minimal link smoke check. All relative links in the new documentation
were separately resolved on disk. This does not certify every external URL.
No upstream instrumentation sources or changelogs were modified.
Suggested conventional commit: `feat: add opt-in Ruby security telemetry`.

## Limits

Only Linux CRuby 3.3.12 was executed locally. The scoped CI workflow requests
3.3/3.4/4.0 runs; unexecuted CI is not evidence for those versions. JRuby, Rails,
other operating systems, alternative clients, sanitizer/attack analysis,
complete SBOM coverage, backend ingestion and DataKit acceptance remain outside
this evidence. All observations are approximate with unknown attack evidence.
The v1.0.0 source-release acceptance record is unchanged.
