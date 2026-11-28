# CalVer transition: October–December 2026

The transition starts with the **`v0.7.7-alpha.3`** release, not the 0.7.6 train.
Its primary version is **`vYYYY.M.D-alpha`**, using the actual UTC release date;
`v0.7.7-alpha.3` is only a temporary compatibility alias. No release date is
checked into the workflow or chart metadata.
Release tags supply the canonical date to every build.
Git tags include `v`; Docker tags and chart versions do not.

`.sure-version` is generated build metadata, ignored by Git. The Docker workflow
writes it into the build context before packaging; Rails, Sentry and backups
continue reading that immutable file inside the image. Source checkouts without
it use `0.0.0-dev.<commit_sha>` (or `0.0.0-dev.unknown` when unavailable). Local Docker builds
can generate the file explicitly to label their image; without it they are dev builds.

Tagged releases derive their version from the tag, so retries retain the same
identity. Manual builds selecting a canonical tag retain its version but remain
non-releases: they publish only the selected commit’s SHA image tag when requested. Untagged Docker builds use the original workflow run's UTC date
(`YYYY.M.D-alpha`); retries retain that date. They keep the existing SHA tags and do not
promote `stable` or `latest`. Scheduled builds additionally publish floating
`nightly` and unpadded `YYYY.M.D-nightly` Docker tags (for example,
`2026.11.1-nightly`), using that same original UTC run date on retries.
Dated tags replace the rotating weekday tags; existing images and tags are
not deleted, and no retention or cleanup policy is changed.

Desktop and mobile release builds also derive their versions from the release
tag. Standalone mobile branch builds retain their explicit pubspec version.
Release chart packages are stamped from the release tag; chart-only releases
select an existing immutable image via the `app_version` dispatch input (or an
explicit Chart.yaml appVersion for chart-tag pushes). The checked-in chart has
development defaults; it does not claim to be a dated release. No version write-back
commits or channel-state files are needed.

## Releasing

1. Land this change on `main` before cutting the 0.7.7 alpha.3 candidate.
   Leave 0.7.6, 0.7.7-alpha.1 and 0.7.7-alpha.2 unchanged. Carry it to the 0.7.7 release branch
   when that branch is cut; do not backport the transition to 0.7.6.
2. Generate the canonical tag from the UTC build day, once, when starting the release:
   `tag="v$(date -u +%Y.%-m.%-d)-alpha"` (omit `-alpha` for stable).
   Push that tag at the intended release commit; retries reuse it, even after midnight.
   In `publish.yml`, `COMPATIBILITY_CHANNEL: alpha` selects alpha releases and
   `COMPATIBILITY_VERSION: 0.7.7-alpha.3` supplies the legacy alias. No date edit is
   needed. Before a subsequent release, advance the legacy alias; for stable set
   the channel to `stable` and alias to `0.7.7`. Clear the alias to opt out.
3. Push only the canonical tag. The workflow creates/verifies the legacy Git
   tag without force, publishes both Docker names against one manifest, and
   packages both Helm versions pointing to the canonical image.
4. Verify both Docker names resolve to the same digest and check the canonical
   GitHub Release and its assets. There is no duplicate legacy GitHub Release.

The alias applies only to tagged 2026 releases in the selected channel. Untagged
builds and the other channel never receive it. Advance the legacy alias before
each new release: leaving an already-used alias fails safely rather than moving it. Manually
pushing the alias does not trigger another build or deployment. An existing alias
on another commit blocks publication; retries never move it. Platform-image
digests may have been built before that check, but named images and charts have not.

## Version names

Use unpadded `YYYY.M.D-alpha` for alpha releases, `YYYY.M.D-rc.N` for
release candidates (N is a nonnegative integer without leading zeroes), and
`YYYY.M.D` for stable releases. All use the actual UTC release date.

Alpha releases publish their exact versioned Docker image and update `latest`,
never `stable`. RC releases publish version-specific tags only: neither `latest`
nor `stable` moves. Both use the alpha Render deployment path and are marked as
GitHub prereleases. Stable releases update `stable` and use the stable deployment
path. The GitHub prerelease checkbox does not override the tag-based workflow classification.

During the compatibility window, RC releases also use `COMPATIBILITY_CHANNEL:
alpha`. Advance `COMPATIBILITY_VERSION` to an unused legacy alias before each new
release (or clear it); an existing alias pointing to another commit blocks
publication. RC identity remains intact in the image, Helm appVersion and Android
version name; iOS uses the numeric date, as it does for alpha.

Publish at most one alpha and one stable per UTC day; numbered RCs allow multiple
candidates on that date. A retry reuses the same tag and commit; a new candidate
increments N without moving an existing tag. Beta, numbered alpha and hotfix
suffixes remain unsupported. Cut release branches as usual; daily fixes do not
create new ones.

## January

Stop issuing legacy aliases and clear the two compatibility settings. The
workflow only emits them for 2026 dates. Keep historical tags, images and chart
packages for pinned installations and rollback. The temporary alias steps can
then be removed from the workflow—there is no library or registry to migrate.
