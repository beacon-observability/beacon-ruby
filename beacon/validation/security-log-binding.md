# Security log binding adoption validation

Current source pins specification `d9d76e5a41d974d294bb596e06918bb954319bf6`
and output profile `beacon-security-log-body-v1`. This is source validation,
not release acceptance or a claim about every receiver.

The producer retains v2 fields at their existing paths, moves `observed_at` to
native event time and `occurrence_id` to log attribute `event_id`, and emits a
compact single-line JSON Body. The original inventory identity tuple and
fingerprint v1 remain unchanged. Byte budgets use the transmitted UTF-8 Body.

## Verification

- Ruby 3.3.12: `bundle exec rake test` in `security/` ran 28 tests and 198 assertions with no failures; two database-dependent tests were skipped.
- Security line coverage was 94.10%, above the required 85%.
- The SDK integration test verifies direct Body decoding and active invocation span association. Shared examples cover exact native metadata, invalid times and repeatable inventory/occurrence IDs.
- All eight modified Ruby files and both added Ruby files passed targeted RuboCop checks.
- Root formatting and Markdown lint passed. `npm run check` reached the link checker, which could not run because its required Chrome 154 executable is absent. The root lint pass also reports 340 existing informational/style findings outside this change; modified files pass targeted lint.

A standalone runtime export through the real Ruby SDK and Collector 0.135.0 also
passed exact native timestamp, compact Body and repeated event-ID checks (two
records). Other Ruby/platform matrices were not run in this change.
Body-only diagnostic archives omit event time and occurrence identity; native OTel
metadata is required when those values are needed.
