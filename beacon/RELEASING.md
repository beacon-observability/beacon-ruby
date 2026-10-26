# Beacon Ruby Release Prerequisites

Beacon Ruby has no official release or published Beacon gem. The imported
`opentelemetry-*` gem versions and upstream release scripts do not constitute a
Beacon publishing entry point.

Before an initial release:

1. Define the Beacon distribution, public gem and command names, artifact scope,
   and independent versioning. Verify RubyGems ownership and publishing permission
   before selecting names; do not republish unchanged upstream gems under their
   existing identities.
2. Pin the source baseline and exact Core and component dependencies. Retain
   upstream licenses and required notices, and document every Beacon-specific
   change.
3. Build candidate artifacts from pinned source, inspect their metadata and
   contents, and install those artifacts in clean target environments.
4. Validate the declared Ruby engines and versions, selected framework and client
   integrations, application lifecycle, and real OTLP receiver path. Record the
   protocols, receiver versions, known limitations, and regression results.
5. Establish a narrowly scoped Beacon release process with confirmed destinations,
   least-privilege credentials, immutable tags and artifacts, checksums, release
   notes, and upgrade and rollback instructions. Archived upstream publishing
   workflows must not be re-enabled without review.
6. After authorized publication, reinstall from the public channel and validate
   the exact artifacts. Add confirmed repository and version-pinned installation
   and release links to the product repository's
   [language index](https://github.com/beacon-observability/beacon/blob/main/docs/languages.md#ruby).

Packaging, local tests, receiver acceptance, and public publication are separate
states. A successful source import is not an official Beacon release.
