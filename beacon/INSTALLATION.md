# Beacon Ruby v1.1.0 Source Installation

`v1.1.0` distributes the complete Beacon Ruby source snapshot through GitHub
Releases. It preserves official OpenTelemetry Ruby Contrib gem identities and
versions, with Core API, SDK, and exporter gems used as dependencies. It adds the opt-in `beacon-security-0.1.0.gem` GitHub Release asset. This release
does not publish a `beacon-ruby` gem, an executable agent, or a zero-code preload.

The validated environment is Ubuntu 24.04 x86_64 with CRuby 3.3.12 and Bundler
2.5.22. The source gem specifications require Ruby 3.3 or newer, with Security integration CI also passing on Linux CRuby 3.3, 3.4 and 4.0.
Collector acceptance remains scoped to CRuby 3.3.12; other engines and platforms
have not been qualified.

## Download and Verify

Download the four assets from the
[v1.1.0 GitHub Release](https://github.com/beacon-observability/beacon-ruby/releases/tag/v1.1.0)
into a new directory:

```sh
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.1.0/beacon-ruby-1.1.0-source.tar.gz
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.1.0/beacon-security-0.1.0.gem
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.1.0/SOURCE.txt
curl -fLO https://github.com/beacon-observability/beacon-ruby/releases/download/v1.1.0/SHA256SUMS
sha256sum -c SHA256SUMS
tar -xzf beacon-ruby-1.1.0-source.tar.gz
cd beacon-ruby-1.1.0
```

`SOURCE.txt` records the exact Beacon source commit and official upstream baseline.
The archive includes source and licenses; it does not include `.git` history,
downloaded dependencies. The Security gem is a separate checksum-verified asset. Full history remains available
in the source repository. As an alternative to the archive, clone the fixed tag:

```sh
git clone --branch v1.1.0 --single-branch https://github.com/beacon-observability/beacon-ruby.git beacon-ruby-1.1.0
cd beacon-ruby-1.1.0
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
[v1.1.0 release notes](releases/1.1.0.md).

## Enable Security

Security is opt-in and uses an application's existing OpenTelemetry Logs SDK and
exporter configuration. The gem is distributed on GitHub, not RubyGems. From the
directory containing the downloaded assets:

```sh
gem install ./beacon-security-0.1.0.gem --no-document
```

The runtime dependencies come from RubyGems. Add the installed exact version to
an application's Gemfile, or use the extracted source with
`gem 'beacon-security', path: '/absolute/path/to/beacon-ruby-1.1.0/security'`.
Require the application's clients before `Beacon::Security.start`, and add
`Beacon::Security::Middleware` inside its OTel Rack server-span middleware.
Set `BEACON_SECURITY_ENABLED=true`; local diagnostic files remain disabled.

For a synthetic Security receiver check from the extracted repository root:

```sh
cd security
BUNDLE_FROZEN=true bundle install
BUNDLE_FROZEN=true python3 test/collector_smoke.py
```

This development test bundle also includes database client gems; MySQL's native
gem needs client development headers/libraries. Applications need only the runtime
gem dependencies and their own Rack/SDK/exporter/client dependencies. See the
[Security guide](../security/README.md) for complete startup and shutdown examples,
configuration, modeled sources/sinks, budgets and limits, and the
[release acceptance](validation/security-1.1.0.md) for artifact verification.
Findings use approximate substring correlation with unknown attack evidence;
they are not confirmed vulnerabilities. Runtime inventory covers activated gems.

## Upgrade and Rollback

Keep each version in a separate directory and retain the verified archive, gem,
`SOURCE.txt`, checksums, application Gemfile/lockfile and initialization. Review
release notes before changing source or dependency references.

To disable Security, set `BEACON_SECURITY_ENABLED=false` and restart the process.
To roll back the release, restore the previous verified source reference,
application Gemfile/lockfile and SDK initialization, restart and verify telemetry.
The v1.0.0 release has no Security capability. Do not overwrite upstream gems or
previously published Beacon assets.
