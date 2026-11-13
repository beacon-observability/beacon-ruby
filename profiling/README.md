# Beacon Ruby Profiling

Opt-in, experimental profiling for CRuby 3.3+ on Linux. Beacon Ruby v1.2.1 distributes this gem
as a GitHub Release asset; it is not published to RubyGems.
This source tree prepares v1.2.1; download commands apply after publication.

## Install and start

Install the checksum-verified `beacon-profiling-0.1.1.gem` from the
[v1.2.1 release](https://github.com/beacon-observability/beacon-ruby/releases/tag/v1.2.1)
with `gem install ./beacon-profiling-0.1.1.gem --no-document`, then add
`gem 'beacon-profiling', '= 0.1.1'` to the application's Gemfile. CRuby development
headers and a C11 compiler are required. Alternatively use the released source
and run `bundle install`:

```ruby
gem 'beacon-profiling', path: '/absolute/path/to/beacon-ruby/profiling'
```

Enable profiling and upload to local DataKit:

```sh
export OTEL_PROFILING_ENABLED=true
export OTEL_PROFILING_EXPORTER=http
export OTEL_PROFILING_ENDPOINT=http://127.0.0.1:9529/profiling/v1/input
export OTEL_SERVICE_NAME=my-ruby-service
export OTEL_RESOURCE_ATTRIBUTES=service.version=1.0,deployment.environment.name=local
# Preload after Bundler has resolved the application Gemfile.
bundle exec ruby -rbeacon/profiling/auto app.rb
```

Alternatively, initialize explicitly with `require 'beacon/profiling'` followed by
`Beacon::Profiling.start`. A disabled preload does not load the native sampler.
With profiling enabled, HTTP export defaults to local DataKit unless a file path
or another exporter is selected. This differs from the initial implementation,
which silently wrote files when no upload URL was configured.

Enable additional collectors as needed:

```sh
export OTEL_PROFILING_TYPES=wall,cpu
export OTEL_PROFILING_MEMORY_ENABLED=true
export OTEL_PROFILING_EXCEPTION_ENABLED=true
```

Wall sampling runs concurrently with native CPU or allocation sampling. Within an
export window, CPU and allocation share equal native sampling slices because
StackProf supports one native session at a time. With both enabled and a 60-second
export window, each native type is sampled for about 30 seconds. Values describe
the observed slices and are not extrapolated to 60 seconds. All observed types
are combined into one HTTP profile, with zero values in unrelated type columns.
Allocation samples estimate allocated object counts, not object sizes or live heap bytes.
Exceptions run concurrently, sampling exception classes and Ruby stacks; messages,
exception objects, locals and request data are never retained.

## Runtime and shutdown

For Puma preloaded applications, initialize inside the worker hook:

```ruby
on_worker_boot do
  Beacon::Profiling.after_fork
end

on_worker_shutdown do
  Beacon::Profiling.stop
end
```

Use the equivalent post-fork hook in Unicorn. `after_fork` discards inherited
sampler state and export queues and starts a child-owned session. It does not
upload parent snapshots or change the parent. The library does not patch `fork`.
Without an explicit child hook, inherited state will not upload at child exit.

The sampling worker detaches a snapshot and resumes sampling before the export
worker performs encoding or networking. The export queue holds at most two
windows; a full queue drops a new window rather than blocking sampling. Exception samples and unique wall stacks are capped per collection slice. Wall sampling
excludes profiler workers and the standard-library Timeout watcher and includes at most the configured number of threads. StackProf's own raw buffer still grows with stack
diversity during a window; use shorter windows to reduce peak memory.

`Beacon::Profiling.stop` flushes the final window and waits within the configured
shutdown deadline. If it returns `false`, pending export continues while the
process lives; a second profiler cannot start until both workers finish. Normal
process exit invokes stop automatically. Forced termination can lose data.

Inspect process-local status with `Beacon::Profiling.stats`: `active`, `running`
(sampling worker), `pending` (queued windows), `collected`, `exported` (HTTP records or local files), `failed`, and `dropped` (windows). A completed HTTP request increments
`exported` only for a successful HTTP status; this does not prove backend storage.
Failures log exception classes and, for receiver rejections, the HTTP status.
Credentials, response bodies and URLs are never logged.

## Export compatibility

`http` selects the existing DataKit-compatible multipart/pprof uploader.
The legacy `datakit` and `pprof_http` names remain accepted. `otlp` is reserved
for a future OTLP Profiles implementation and is currently unsupported.
The endpoint and other settings are unchanged.

Uploads use a multipart `auto` attachment named `auto.pprof` plus an `event` part
named `event.json`, with `language=ruby`, `family=ruby`, timestamps and resource
tags. The legacy `profiler=ddtrace` value identifies the compatible DK multipart
protocol. A single HTTP record contains the observed sample types for the complete
export window, enabling type selection in the same profile detail. Local file
export retains separate files for each collection slice, with that slice's actual
start time and duration rather than the full export window. The layout
matches the Ruby fixture in DataKit's profile input. Sample types are `cpu-time`,
`wall-time` (nanoseconds), `alloc-samples` and `exception-samples` (counts), plus
unweighted `samples` counts. Files are gzip-compressed pprof protobuf.

HTTP(S) uploads verify TLS, have total and socket timeouts, and do not retry.
Rejected windows are dropped, not replayed. Slow or failed receivers do not stop
sampling. This is a pprof bridge, not the OTLP Profiles signal; a traces endpoint
cannot receive these payloads. See [acceptance](ACCEPTANCE.md) for validated scope.

The exporter maps `OTEL_SERVICE_NAME` (overriding resource `service.name`),
`service.version`, `deployment.environment.name` (falling back to
`deployment.environment`) and `host.name` to `service`, `version`, `env` and `host`.
It also sends Ruby engine/version and profiler version. Only these allowlisted
resource attributes are exported. Commas and newlines in tag values are replaced.

Exception samples include a thread ID and, if the application has loaded the
OpenTelemetry API and has an active valid span, `trace id` and `span id` labels.
This reads context on the application thread where the exception occurred;
native StackProf CPU/wall/allocation samples do not carry trace correlation.

## Configuration

| Variable                                     | Default                                    | Meaning                                                                                                       |
| -------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `OTEL_PROFILING_ENABLED`                     | `false`                                    | Enable with `true`, `1`, `yes` or `on`.                                                                       |
| `OTEL_PROFILING_TYPES`                       | `wall`                                     | Comma-separated `wall`, `cpu`, `allocations`. CPU/allocation share the export window; wall runs concurrently. |
| `OTEL_PROFILING_MODE`                        | `wall`                                     | Legacy single-type option; `TYPES` takes precedence.                                                          |
| `OTEL_PROFILING_SAMPLE_INTERVAL`             | `0.01`                                     | Sampling period in seconds, 0.001–1.                                                                          |
| `OTEL_PROFILING_SAMPLING_INTERVAL`           | `10000`                                    | Legacy microsecond interval; `SAMPLE_INTERVAL` takes precedence.                                              |
| `OTEL_PROFILING_EXPORT_INTERVAL`             | `60`                                       | Collection window in seconds, 0.1–300.                                                                        |
| `OTEL_PROFILING_UPLOAD_INTERVAL`             | `60`                                       | Legacy seconds; `EXPORT_INTERVAL` takes precedence.                                                           |
| `OTEL_PROFILING_MEMORY_ENABLED`              | `false`                                    | Adds allocation windows.                                                                                      |
| `OTEL_PROFILING_MEMORY_SAMPLING_INTERVAL`    | `1000`                                     | One sample per N object allocations, 1–1000000.                                                               |
| `OTEL_PROFILING_EXCEPTION_ENABLED`           | `false`                                    | Enables exception stack sampling.                                                                             |
| `OTEL_PROFILING_EXCEPTION_SAMPLING_INTERVAL` | `100`                                      | Captures every Nth raised exception.                                                                          |
| `OTEL_PROFILING_MAX_EVENTS`                  | `1000`                                     | Maximum retained exception samples and unique wall stacks per collection slice, 1–10000.                      |
| `OTEL_PROFILING_MAX_THREADS`                 | `128`                                      | Maximum wall-sampled Ruby threads per tick, 1–1024.                                                           |
| `OTEL_PROFILING_MEMORY_IGNORE_PROFILER`      | `true`                                     | Excludes native samples whose stacks include profiler implementation frames.                                  |
| `OTEL_PROFILING_MAX_FRAMES`                  | `64`                                       | Exported stack depth, 1–512. Native capture depth is unchanged.                                               |
| `OTEL_PROFILING_INCLUDE_TRACE_CONTEXT`       | `true`                                     | Exception trace/span labels; `false` disables them.                                                           |
| `OTEL_PROFILING_EXPORTER`                    | Automatic                                  | `http` / `pprof_http` (legacy alias: `datakit`), `pprof` / `file`, or `none`.                                 |
| `OTEL_PROFILING_PPROF_UPLOAD_URL`            | `http://127.0.0.1:9529/profiling/v1/input` | HTTP(S) destination.                                                                                          |
| `OTEL_PROFILING_ENDPOINT`                    | Same local URL                             | Endpoint alias; explicit upload URL takes precedence.                                                         |
| `OTEL_PROFILING_PPROF_HEADERS`               | Empty                                      | Comma-separated `name:value` headers; values may be percent encoded.                                          |
| `OTEL_PROFILING_UPLOAD_TIMEOUT`              | `5`                                        | Total and socket timeout in seconds, 0.1–60.                                                                  |
| `OTEL_PROFILING_SHUTDOWN_TIMEOUT`            | `10`                                       | Maximum shutdown wait in seconds, 0.1–60.                                                                     |
| `OTEL_PROFILING_PPROF_PATH`                  | `otel-profiles`                            | Local directory. Explicit path without upload URL selects files.                                              |
| `OTEL_PROFILING_MAX_FILES`                   | `20`                                       | Retained files for the current process in this directory.                                                     |

Explicit exporter selection wins over automatic selection. Setting `none` prevents
sampler startup. Invalid configuration is isolated from application startup.
Changing configuration requires stopping and restarting the profiler.

Local files have mode `0600`; new directories have mode `0700`. Retention deletes
only matching profiler files with the current PID. It does not clean files from
previous processes; configure external retention for shared output directories.
Stacks contain function names and source paths; restrict output access.

## Verification and remaining limits

```sh
bundle install
bundle exec rake test
bundle exec appraisal rake test
OTEL_PROFILING_ENABLED=true OTEL_PROFILING_PPROF_PATH=/tmp/ruby-profiles bundle exec ruby -Ilib examples/workload.rb
```

The example runs for 125 seconds by default, allowing complete 60-second export windows. Override `BEACON_PROFILE_EXAMPLE_DURATION` only for a short
smoke test. Shutdown exports a final partial window with its actual duration;
that shorter tail is not padded to 60 seconds.

Tests cover actual sampling and HTTP uploads, profile value/unit/depth semantics,
metadata and header validation, privacy, bounded exception buffers, queue limits,
shutdown deadlines, retention, trace context and fork ownership.

The StackProf backend lacks live heap byte attribution, lock contention profiles,
OTLP Profiles export, and CPU/wall trace correlation. The optional Beacon backend
below adds live heap bytes and GVL timing.
Wall sampling reads bounded Ruby thread backtraces at timer ticks. It includes
waiting threads but is subject to GVL scheduling; it is not a complete per-thread
timeline and can miss short-lived threads. Native stacks and JRuby are unsupported. Exception TracePoint
hooks and allocation sampling add workload-dependent overhead; benchmark before
production use. No production overhead or complete runtime matrix is claimed.

## Beacon-owned native heap and GVL recorder

The `beacon` backend builds the C extension shipped in this gem. It does not
install or load `datadog`, `libdatadog`, or a separate compression library.
The copied/adapted thread storage helpers and heap tracking design are attributed
in [provenance](licenses/provenance.json), with the original BSD license and notice
under `licenses/`. All runtime entry points are in the Beacon namespace.

For source development, build once with `bundle exec rake compile`. Installing the
gem compiles its extension through RubyGems. CRuby development headers and a C11
compiler are required, in addition to the normal StackProf requirements.

```sh
export OTEL_PROFILING_ENABLED=true
export OTEL_PROFILING_BACKEND=beacon
export OTEL_PROFILING_TYPES=wall,cpu
export OTEL_PROFILING_MEMORY_ENABLED=true
export OTEL_PROFILING_HEAP_ENABLED=true
export OTEL_PROFILING_HEAP_SIZE_ENABLED=true
export OTEL_PROFILING_GVL_ENABLED=true
export OTEL_SERVICE_NAME=my-ruby-service
bundle exec ruby -rbeacon/profiling/auto app.rb
```

CPU/allocation still use StackProf's collection slices. The Beacon extension
observes heap allocations and GVL events alongside those slices. All observed
measurements are combined into the existing pprof upload; no foreign scheduler,
SDK components or transport is initialized. Exception collection can also remain
enabled with this backend.

The native recorder adds:

- `heap-live-samples`: weighted samples of objects that have not been reclaimed.
- `heap-live-size`: `ObjectSpace.memsize_of` bytes for sampled live objects,
  multiplied by the allocation sampling stride. These are shallow owned bytes,
  not RSS, cumulative allocation bytes or the retained size of an object graph.
- `gvl-wait-time`: observed waits of at least one millisecond, attributed to a
  stack captured after GVL acquisition when the resumed thread is current.
- `timeline`: those same observed GVL waits with thread identity, state and end
  timestamps. Rendering depends on receiver/UI support; this is a partial GVL
  timeline, not a complete CPU execution timeline.

`OTEL_PROFILING_HEAP_SAMPLE_EVERY` defaults to `1000` (range 1–1000000). Every Nth
allocation is sampled; counts and bytes carry that weight. `MAX_EVENTS` bounds
tracked heap objects and captured GVL events separately. Once capacity is full,
new samples are dropped and counted. Dead heap slots are reclaimed at a limited
rate when capacity is exhausted. Review the drop counters before interpreting a
small sample as representative of the whole application. A stride of `1` is for
small synthetic checks, not a production recommendation.

Live heap objects and bytes use only the last snapshot in an export window;
CPU, wall and wait durations accumulate across collection slices.

Allocation callbacks copy frames into preallocated memory. Ruby method calls and
weak-map insertion are deferred to VM-safe postponed jobs. Up to 256 pending
objects are briefly held strongly until insertion; tracked objects subsequently
use the VM's weak map so GC and compaction can release or move them safely. Object
contents and exception messages are not collected. Heap sizing occurs at snapshot
time, not while an allocation event is running.

GVL timing uses Ruby 3.3+ thread events and the adapted thread-local storage
helper. READY callbacks make no Ruby method calls and store timing in stable
atomic storage; exited-thread slots are reclaimed. Samples are bounded; missing stacks are left unattributed rather
than assigned to another thread. The current ractor is observed; broader Ractor
workloads and non-Linux runtimes have not been qualified.

`OTEL_PROFILING_HEAP_ENABLED=true` selects `beacon` if no backend is specified.
Heap size defaults on when heap tracking is enabled; GVL defaults on for `beacon`.
Use the existing post-fork hook to rebuild process-local state. Other native
profilers still must not run concurrently with StackProf's signal sampling.

For the synthetic live-heap/GVL example:

```sh
bundle exec ruby -Ilib examples/heap_workload.rb
```

It retains strings through a complete window and creates two contending threads.
`Beacon::Profiling.stats[:native]` exposes `gvl_waiting_time_ns_total`,
`heap_samples_observed`, `heap_samples_dropped` and `gvl_samples_dropped`.
Both heap samples and GVL timeline events remain workload-dependent estimates;
benchmark overhead before production use.
