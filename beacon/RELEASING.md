# Beacon Ruby Source Releases

Beacon Ruby versions identify independent source snapshots. The initial version is
`v1.0.0`. Individual `opentelemetry-*` gems retain their upstream identities and
versions. This process publishes to GitHub Releases, not RubyGems. The archived
upstream publishing workflows are reference material and must remain disabled.

## Prepare and Validate

1. Start from a clean downstream branch containing the reviewed upstream baseline.
   Keep source provenance, licenses, required notices, and Beacon-specific changes
   traceable. Review all changes since the previous Beacon release.
2. Update the English source installation guide and versioned release notes with
   the actual artifact scope, dependency pins, validated environments, limitations,
   and rollback procedure. Source availability is not a complete support claim.
3. Run the repository checks and the selected component tests described in the
   [acceptance record](validation/README.md). Validate the actual receiver path.
4. Commit the release documentation and record its full commit. Build from that
   commit, not from a worktree containing uncommitted files.

## Build Immutable Source Artifacts

Run from the repository root, using a new output directory outside the source tree:

```sh
beacon_release_version=1.0.0
beacon_release_commit=$(git rev-parse HEAD)
beacon_release_dir=../beacon-ruby-release-${beacon_release_version}
mkdir "$beacon_release_dir"
git archive --format=tar --prefix="beacon-ruby-${beacon_release_version}/" "$beacon_release_commit" |
  gzip -n > "$beacon_release_dir/beacon-ruby-${beacon_release_version}-source.tar.gz"
```

Create `SOURCE.txt` in the output directory with the product version, exact source
commit, intended tag, official upstream repository, adopted upstream tag and full
commit, and paths to the dependency lock and acceptance record. Generate checksums
for the archive and provenance file:

```sh
(cd "$beacon_release_dir" && sha256sum "beacon-ruby-${beacon_release_version}-source.tar.gz" SOURCE.txt > SHA256SUMS)
(cd "$beacon_release_dir" && sha256sum -c SHA256SUMS)
```

Extract the archive into a clean directory. Compare its files with the release
commit, verify that licenses and the validation lockfile are present, and confirm
that active upstream workflows, local caches, credentials, and build output are
absent. Install the locked smoke-check dependencies and run the Collector check
from the extracted source. Build and inspect the selected component gems from that
archive if those components are part of the acceptance scope. Keep the tested
artifacts unchanged for upload.

## Publish and Verify

Confirm write access to `beacon-observability/beacon-ruby`. Create an annotated
version tag at the validated source commit, and push the downstream branch and that
specific tag. Do not use `git push --tags`: the clone also contains upstream tags.
Never move a published Beacon tag or replace published artifacts under the same
version; use a new release version for fixes.

Create a draft GitHub Release with the English versioned release notes. Upload the
tested source archive, `SOURCE.txt`, and `SHA256SUMS`. Verify the draft's tag,
target commit, asset names, sizes, and digests, then publish the release. No
RubyGems credentials or upstream publishing identity are needed for this source
release process.

After publication, download all three assets from the public release and verify
`SHA256SUMS` again. Run acceptance from the downloaded archive, confirm that
version-pinned documentation is publicly accessible, and update the product
repository's [language index](https://github.com/beacon-observability/beacon/blob/main/docs/languages.md#ruby).
The release record is authoritative for the published artifact scope.

A future installable Beacon gem requires a separate package identity, confirmed
RubyGems ownership and publication permission, clean artifact installation,
versioned application configuration, and validation of its declared runtime and
instrumentation support. A source release does not imply that this work is complete.
