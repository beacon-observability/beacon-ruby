# Beacon Ruby v1.1.0 acceptance

Release acceptance uses the unchanged Security runtime from merged PR #1 and the
committed v1.1.0 documentation. Source provenance is recorded in the Release's
`SOURCE.txt`; schema v2 and fingerprint v1 are pinned in `security/contract.json`.

## Runtime and tests

Local Ubuntu 24.04 x86_64 uses CRuby 3.3.12 and Bundler 2.5.22. Security integration
CI also passes Linux Ruby 3.3, 3.4 and 4.0. The Security suite has 22 tests and
133 assertions, with no failures/errors/skips and 95.48% line coverage, including
disposable PostgreSQL 16.15 and MySQL 8.4 services. Its current Appraisal passes.

The inherited base and three Net::HTTP semantic-mode tests retain their original
scope in the [v1.0.0 acceptance](README.md). Security flow precision, budgets,
performance evidence and gaps are in the [Security acceptance](../../security/ACCEPTANCE.md).

## Artifact checks

The immutable archive is built from a committed Git tree using `git archive`
and gzip without a timestamp. Extraction is compared byte-for-byte with that
tree; dependencies, caches, `.git` and build output are excluded. The Security gem
is built from extracted source, installed in a new gem home, and checked without
a local source path. The archived upstream publishers remain outside the active
workflow directory; the single active workflow is Beacon Security CI.

The Security Collector check and the existing Net::HTTP Collector smoke check
run from extracted source. Security receipt is also checked with the independently
installed gem. After publication the four assets are downloaded, SHA-256 checks
are repeated and both Collector paths are exercised from downloaded source.

These checks establish synthetic local Collector delivery, not backend/DataKit
acceptance, a complete framework matrix or confirmed vulnerability detection.
