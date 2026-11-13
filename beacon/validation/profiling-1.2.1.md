# v1.2.1 profiling candidate acceptance

This candidate contains source version v1.2.1 and profiling gem 0.1.1. The gem
version and exported `profiler_version` tag must agree. Security 0.1.0 and its
previous acceptance scope remain unchanged.

Local CRuby 3.3.12 main and Appraisal suites each passed 27 tests and 152
assertions, with 93.02% Ruby line coverage. The built gem installed with its
StackProf dependency in an isolated gem directory. A real local HTTP receiver
validated the installed gem version, `profiler_version=0.1.1`, multipart metadata
and gzip pprof contents using `EXPORTER=http`. Scoped RuboCop, Markdown and
format checks passed. Source build checks do not prove publication.

Repository-wide checks still report inherited style offenses outside the changed
profiling files. Record the final source commit and tested artifact digests with
the release assets; public receiver/download acceptance follows publication.

The merged HTTP configuration change passed Linux CRuby 3.3/3.4/4.0 CI and a
DataKit-to-Guance check. Candidate-specific version and installed-artifact checks
are recorded in the release PR. The full inherited instrumentation matrix and
native C branch coverage are outside this patch's acceptance scope.

The source installation guide retains the selected trace/Collector harness and
Security checks required by the release procedure. Do not replace published
v1.2.0 assets. Public download and checksum verification still follows publication.
