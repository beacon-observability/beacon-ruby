# Beacon Ruby Development Guide

Beacon Ruby starts from the complete official
[OpenTelemetry Ruby Contrib](https://github.com/open-telemetry/opentelemetry-ruby-contrib)
source and Git history. This is an independent downstream repository, not a GitHub
fork. The source repository is
[beacon-observability/beacon-ruby](https://github.com/beacon-observability/beacon-ruby).
The initial source release is `v1.0.0`. See the [source installation guide](INSTALLATION.md)
and [release notes](releases/1.0.0.md) for the fixed release scope and limitations.

The selected maintenance model preserves instrumentation sources so that future
Beacon changes can be made and reviewed in their native modules without losing
upstream history. The API, SDK, and exporters remain dependencies from official
[OpenTelemetry Ruby Core](https://github.com/open-telemetry/opentelemetry-ruby);
Core is not copied into this repository. There is no pre-existing Beacon Ruby
implementation being migrated in this import.

## Source and Development

- [Baseline and synchronization](UPSTREAM.md) record the adopted upstream tag and
  full commit. The upstream component version is not a Beacon product version.
- [Instrumentation](../instrumentation/) contains the original framework and
  client integrations, including the shared base and aggregate instrumentation gem.
- [Contributing](../CONTRIBUTING.md) and the
  [instrumentation guide](../instrumentation/CONTRIBUTING.md) describe the upstream
  development tools and component tests.
- [Release maintenance](RELEASING.md) describes source packaging, acceptance, and
  GitHub publication.

Use Ruby 3.3 or newer as required by the imported gem specifications. This is an
upstream requirement, not a validated Beacon support matrix. Each gem retains its
own dependencies and tests. For an initial shared-base check, run from the repository
root:

```sh
cd instrumentation/base
bundle install
bundle exec rake test
```

For a representative HTTP integration, run separately from the repository root:

```sh
cd instrumentation/net_http
bundle install
bundle exec appraisal install
bundle exec appraisal rake test
```

Use Appraisal as described in the upstream contributing guide to exercise a
component's dependency matrix. A focused test does not validate all instrumentations,
runtime environments, or a real receiver path.

## Automation and Current Scope

The inherited workflows are archived under
[`upstream-workflows/`](upstream-workflows/), outside GitHub's executable workflow
directory. They remain upstream reference material, including publishing and bot
configuration. No Beacon CI or release workflow is enabled in this initial import.
Review required permissions, package ownership, destinations, and execution cost
before adopting any automation.

The import retains upstream instrumentation behavior and package identities. Three
Net::HTTP connection-error tests use a deterministic socket failure instead of
relying on an external host. A [local acceptance harness](validation/README.md)
checks HTTP trace delivery and correlation against an actual Collector. The initial
release distributes source through GitHub. A Beacon-specific installable gem,
configuration layer, and enhancements remain future work in this language repository.

## Initial Import Verification

On 2026-10-26, the imported release tag resolved to the recorded full commit, the
clone was confirmed non-shallow, and Git connectivity checks passed. Runtime
instrumentation code and licenses remain unchanged. Initial environment download
failures were resolved by building an isolated Ruby 3.3.12 runtime from verified
official source and installing the development dependencies.

The shared base tests and all three Net::HTTP semantic modes passed. Local
HTTP/protobuf delivery to OpenTelemetry Collector 0.135.0 was verified. See the
[acceptance record](validation/README.md) for commands, exact dependency locks,
results, and the limits of this verification. The source release retains this narrow
acceptance scope and does not establish a complete supported runtime matrix.
