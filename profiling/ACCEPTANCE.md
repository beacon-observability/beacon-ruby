# Profiling development acceptance

Verified on 2026-11-12 using CRuby 3.3.12, StackProf 0.2.28, Linux x86-64,
Go 1.26.4 pprof and local DataKit 2.17.1. This is an experimental source gem,
not a published release or a complete runtime/performance qualification.

## Implementation and provenance

CPU/allocation sampling uses StackProf; wall sampling uses bounded Ruby thread
snapshots. The optional `beacon` backend compiles the bundled C extension for
heap tracking and GVL events. CPU/allocation use equal slices within an export
window; wall, heap and GVL collection run alongside those slices.

The GVL thread-storage helper is copied/adapted from dd-trace-rb 2.48.0. Heap
tracking ports its deferred-recording/weak-map design into Beacon-owned storage.
Original file hashes, the BSD-3-Clause license and notice are retained under
[`licenses/`](licenses/provenance.json). This is a focused port, not a copy of
all upstream profiler internals. No Datadog package, native storage library,
private VM headers or external compression gem is used at runtime.

The dynamic extension linked only the platform C runtime; its dynamic symbol
table contained no Datadog imports. An isolated installation of the built gem
loaded Beacon, StackProf and Ruby standard libraries only.

## Automated checks

From `profiling/`:

```sh
bundle install
bundle exec rake test
bundle exec appraisal generate
bundle exec appraisal rake test
bundle exec rake build
```

Both suites passed with 23 cases and 129 parent-process assertions, zero
failures/errors/skips. The three native subprocess cases perform additional
assertions. Ruby line coverage was 92.95%, with an enforced 85% minimum; this does
not measure native C branch coverage. The dependency matrix currently exercises
the resolved StackProf 0.2.28 version, not every permitted dependency version.

Checks cover:

- Real CPU, wall and allocation sampling and a real local HTTP receiver.
- Combined profile sample columns, units, stack order/depth, labels and timestamps.
- Heap gauges retaining the last snapshot while CPU/wall/wait samples accumulate.
- Live bytes at a known allocation site decreasing after references are cleared
  and GC runs; a separate ten-cycle GC/compaction check also passed.
- Bounded exception/heap/GVL buffers, file retention, slow receiver queue limits,
  shutdown deadlines and filesystem errors.
- Exception message privacy, active OTel exception context and header injection.
- Parent/child ownership and post-fork native reconstruction.
- Isolated gem installation and absence of Datadog constants or loaded packages.

Scoped Ruby lint, source checks, Markdown and spelling checks passed. The full
`npm run check` stops at its missing Puppeteer Chrome version; a retry using the
installed Chrome exceeded a two-minute link-check budget. Unrelated baseline
files were not modified.

## Complete-window DataKit verification

Run the synthetic heap/GVL workload from `profiling/`:

```sh
export OTEL_PROFILING_ENABLED=true
export OTEL_PROFILING_BACKEND=beacon
export OTEL_PROFILING_TYPES=wall,cpu
export OTEL_PROFILING_MEMORY_ENABLED=true
export OTEL_PROFILING_HEAP_ENABLED=true
export OTEL_PROFILING_HEAP_SAMPLE_EVERY=100
export OTEL_PROFILING_GVL_ENABLED=true
export OTEL_SERVICE_NAME=beacon-ruby-profile-owned-native
export OTEL_RESOURCE_ATTRIBUTES=service.version=profiling-dev,deployment.environment.name=local
bundle exec ruby -Ilib examples/heap_workload.rb
```

This 65-second development run sent one combined 60.163601531-second profile and
one 4.897506660-second shutdown tail. A local inspecting proxy forwarded requests
to `http://127.0.0.1:9529/profiling/v1/input` without changing profile data. Both
uploads received HTTP 200; the run had zero failed uploads or dropped export
windows. Heap/GVL sampling drops were exposed separately and are not counted as
dropped export windows.

The full profile contained CPU time, wall time, allocation counts, heap live
objects, heap live bytes, GVL wait time and GVL timeline events. Standard pprof
parsed the types from the same file. Heap live size was 32.13 MiB attributed to
the synthetic string allocation stack; the workload retained 33,280,000 payload
bytes. The end of the full window and start of the tail were separated by about
3.5 microseconds, using paired native wall/monotonic timestamps.

The stride of 100 above is for a small synthetic workload. The default is 1000.
Counts/bytes carry the sampling weight; dropped samples mean these results are
not a complete heap census or complete timeline. Short shutdown tails keep their
actual duration rather than being padded or discarded.

Local builds install the extension with an atomic rename, preserving already
mapped libraries. A parallel build/load experiment failed during development;
concurrent replacement was identified as a possible cause. Successful full-window
and GC checks subsequently used stable binaries. The built gem was separately
installed into a fresh gem directory, compiled there, and successfully exported
heap profiles without Datadog packages.

## Limits

Heap byte values are shallow owned memory, not RSS, cumulative allocation bytes
or complete retained object graphs. Wall sampling is subject to GVL scheduling.
GVL events are bounded samples of waits of at least one millisecond; UI rendering
of the timeline was not verified. Receiver acceptance and forwarding do not
independently prove that every profile is indexed in a workspace UI.

Production load, native C branch coverage, all supported CRuby versions, broader
Ractor workloads, JRuby, non-Linux systems and authenticated/TLS endpoints were
not qualified. Measure overhead and review native code before production use.
