# Beacon Ruby v1.0.0 Source Installation

`v1.0.0` distributes the complete Beacon Ruby source snapshot through GitHub
Releases. It preserves official OpenTelemetry Ruby Contrib gem identities and
versions, with Core API, SDK, and exporter gems used as dependencies. This release
does not publish a `beacon-ruby` gem, an executable agent, or a zero-code preload.

The validated environment is Ubuntu 24.04 x86_64 with CRuby 3.3.12 and Bundler
2.5.22. The source gem specifications require Ruby 3.3 or newer, but other Ruby
versions, engines, and platforms have not been qualified by this release.

## Download and Verify

Download the three assets from the
[v1.0.0 GitHub Release](https://github.com/beacon-observability/beacon-ruby/releases/tag/v1.0.0)
into a new directory:

```sh
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.0.0/beacon-ruby-1.0.0-source.tar.gz
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.0.0/SOURCE.txt
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.0.0/SHA256SUMS
sha256sum -c SHA256SUMS
tar -xzf beacon-ruby-1.0.0-source.tar.gz
cd beacon-ruby-1.0.0
```

`SOURCE.txt` records the exact Beacon source commit and official upstream baseline.
The archive includes source and licenses; it does not include `.git` history,
downloaded dependencies, or a prebuilt Beacon gem. Full history remains available
in the source repository. As an alternative to the archive, clone the fixed tag:

```sh
git clone --branch v1.0.0 --single-branch https://github.com/beacon-observability/beacon-ruby.git beacon-ruby-1.0.0
cd beacon-ruby-1.0.0
```

## Verify the Selected Instrumentation Path

The checked-in smoke-test Gemfile uses the base and Net::HTTP instrumentation from
this source snapshot and pins the Core SDK and OTLP exporter. Bundler's lockfile
pins the remaining dependency graph. From the extracted repository root:

```sh
cd beacon/validation
BUNDLE_FROZEN=true bundle install
docker pull otel/opentelemetry-collector-contrib:0.135.0
BUNDLE_FROZEN=true python3 collector_smoke.py
```

The harness requires Python 3 and Docker. It pins the Collector image digest,
starts temporary local HTTP and OTLP endpoints, and verifies service identity and
root/client span correlation in the Collector's output. It removes the temporary
servers, container, and trace output after the check. It uses synthetic test
traffic, not a production application or DataKit.

Applications integrate the OpenTelemetry gems explicitly and initialize the SDK
after loading their required libraries. The smoke-check setup demonstrates only
the selected Net::HTTP path. Refer to the component documentation before adapting
it; the imported Rails and other framework integrations are not qualified by this
release. Complete test results and limitations are in the
[source import acceptance record](validation/README.md) and
[v1.0.0 release notes](releases/1.0.0.md).

## Upgrade and Rollback

Keep each version in a separate directory and retain the verified archive,
`SOURCE.txt`, checksums, dependency lock files, and the previous application's
configuration. Review the next release's notes and validate its artifacts before
changing an application's source or dependency references.

To roll back an integration, restore the previously verified source reference,
application Gemfile and lockfile, and SDK initialization, then restart the
application and verify telemetry. For this initial release, an application with
no previous Beacon Ruby integration can restore its original dependencies and
initialization. Do not treat a component source tag as permission to overwrite
already published upstream gems.
