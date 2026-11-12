# v1.2.0 profiling release acceptance

The release is a fixed source snapshot with independently versioned Security and
profiling gem assets. Package digests and the full source commit are recorded in
`SHA256SUMS` and `SOURCE.txt` next to the Release assets.

## Automated verification

The profiling implementation passed Linux CRuby 3.3, 3.4 and 4.0 GitHub Actions
compilation, tests, Appraisal and gem builds. Local CRuby 3.3.12 suites passed
25 tests, 136 assertions and 93.02% Ruby line coverage. The tests include native
GC/fork cases, real local HTTP upload, queue/timeouts/privacy, final empty heap
gauges and actual per-slice file metadata.

The source archive and both gems are built from the committed release tree.
Verify the downloaded `SHA256SUMS`, extract the source and run from `profiling/`:

```sh
bundle install
bundle exec rake test
bundle exec appraisal install
bundle exec appraisal rake test
```

An isolated installation of the profiling gem must compile its bundled extension
and run with StackProf and Ruby standard libraries, without Datadog packages.
The synthetic heap workload in `profiling/examples/heap_workload.rb` is used with
all collectors enabled and a local DataKit profiling input. The normal 65-second
run covers a complete 60-second window and a shutdown tail. Check
`Beacon::Profiling.stats` for successful exports, failures and dropped windows.
Heap/GVL drops are separate sampling counters.

## Inherited paths and limits

Security source has not changed since v1.1.0. Its source tests and Collector
harness, and the original Net::HTTP Collector smoke harness, are rerun from the
release archive. See [Security acceptance](security-1.1.0.md) for the inherited
scope. The full repository check currently stops at a missing Puppeteer Chrome
154.0.8037.57; scoped Ruby, Markdown, formatting and spelling checks are clean.

Native C branch coverage and production overhead are not qualified. A successful
local receiver response does not prove every profile is indexed in a workspace;
GVL timeline rendering is unverified. The [development acceptance](../../profiling/ACCEPTANCE.md)
records the earlier full-window payload inspection and its limitations.
