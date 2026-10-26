# OpenTelemetry Ruby Source and Synchronization

## Initial Baseline

| Item                | Value                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Official source     | <https://github.com/open-telemetry/opentelemetry-ruby-contrib>                                                                                    |
| Adopted release tag | `opentelemetry-instrumentation-all/v0.99.0`                                                                                                       |
| Full commit         | `e433edfa75c29dc1df223721bcbfbb4428f73e09`                                                                                                        |
| Official release    | [Instrumentation All 0.99.0](https://github.com/open-telemetry/opentelemetry-ruby-contrib/releases/tag/opentelemetry-instrumentation-all/v0.99.0) |
| Import date         | 2026-10-26                                                                                                                                        |
| History             | Complete clone, not shallow; 2,294 commits reachable from the adopted baseline                                                                    |
| License             | [Apache-2.0](../LICENSE)                                                                                                                          |

This tag identifies the aggregate instrumentation gem release and the imported
repository snapshot. Individual gems retain their own upstream versions; the
repository does not have one shared component version. Preserve this initial-import
record when adopting later baselines.

Core API, SDK, and exporter code comes from
[OpenTelemetry Ruby Core](https://github.com/open-telemetry/opentelemetry-ruby) as
gem dependencies. The imported component gem specifications and Gemfiles define
their constraints. The [acceptance harness](validation/README.md) pins a narrow
test combination in its own Bundler lockfile. This is not the dependency lock or
support matrix of a Beacon distribution, which has not been established.

## Local Repository Configuration

The local `upstream` remote points to the official Contrib repository. `main` is
the Beacon downstream branch and preserves the adopted release commit as an
ancestor; initial downstream work uses `beacon/onboard-ruby`.
The clone retains the complete upstream history and release tags. Automatic fetching
of additional tags is disabled so that later baselines are selected explicitly.

`origin` points to `https://github.com/beacon-observability/beacon-ruby.git`, and
`remote.pushDefault` is set to `origin`. Never push to the official `upstream`
remote. After cloning, verify `origin` and add the official Contrib repository as
`upstream` for synchronization. Git remotes and local configuration are not included
in commits.

Verify the initial baseline from the repository root:

```sh
git rev-parse --is-shallow-repository
git rev-parse 'opentelemetry-instrumentation-all/v0.99.0^{commit}'
git merge-base --is-ancestor e433edfa75c29dc1df223721bcbfbb4428f73e09 HEAD
```

The expected shallow result is `false`; the tag must resolve to the full commit
recorded above.

## Future Synchronization

1. Select an official release, review its changes, and verify the tag and full
   commit independently. Do not adopt the upstream development branch as a release
   baseline by default.
2. Verify the existing `upstream` URL. Fetch the selected tag into a new reference
   without overwriting an existing tag. Reject unexpected tag movement.
3. Start an isolated branch from the clean Beacon mainline and merge the verified
   commit while preserving history and Beacon-specific differences. Do not replace
   the worktree with a new source archive or squash away upstream provenance.
4. Review component dependencies, licenses, inherited automation, release targets,
   and any conflicts. Keep upstream workflows archived until a specific downstream
   workflow has been reviewed and validated.
5. Test affected components and Beacon enhancements, install built candidate gems
   in clean environments, and validate intended runtime and receiver combinations.
6. Record the adopted baseline and exact validated dependencies after validation.
   Fetching or merging alone does not establish Beacon support or a release.
