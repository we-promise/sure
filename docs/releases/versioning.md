# CalVer transition: October–December 2026

The transition starts with the **`v0.7.7-alpha.2`** release, not the 0.7.6 train.
Its primary version is **`vYYYY.M.D-alpha`**, using the actual UTC release date;
`v0.7.7-alpha.2` is only a temporary compatibility alias. The configured example
is `v2026.10.30-alpha`; update its date if the release happens later.
Release tags supply the canonical date to every build.
Git tags include `v`; Docker tags and chart versions do not.

`.sure-version` is generated build metadata, ignored by Git. The Docker workflow
writes it into the build context before packaging; Rails, Sentry and backups
continue reading that immutable file inside the image. Source checkouts without
it use `0.0.0-dev` (with the commit SHA available separately). Local Docker builds
can generate the file explicitly to label their image; without it they are dev builds.

Tagged releases derive their version from the tag, so retries retain the same
identity. Untagged Docker builds use the original workflow run's UTC date
(`YYYY.M.D-alpha`); retries retain that date. They keep the existing SHA/
nightly registry tags and do not promote `stable` or `latest`.

Desktop and mobile release builds also derive their versions from the release
tag. Standalone mobile branch builds retain their explicit pubspec version.
Release chart packages are stamped from the release tag; chart-only releases
select an existing image through Chart.yaml appVersion. No version write-back
commits or channel-state files are needed.

## Releasing

1. Land this change on `main` before cutting the 0.7.7 alpha.2 candidate.
   Leave 0.7.6 and 0.7.7-alpha.1 unchanged. Carry it to the 0.7.7 release branch
   when that branch is cut; do not backport the transition to 0.7.6.
2. Choose the actual UTC release date for the canonical tag.
   In `publish.yml`, set `COMPATIBILITY_RELEASE` to the complete canonical version (including
   `-alpha` for alpha releases) and `COMPATIBILITY_VERSION` to `0.7.7-alpha.2`.
   For subsequent alphas and stable releases, update this same pair to
   the next unused canonical and legacy versions (stable uses `0.7.7`).
3. Push only the canonical tag. The workflow creates/verifies the legacy Git
   tag without force, publishes both Docker names against one manifest, and
   packages both Helm versions pointing to the canonical image.
4. Verify both Docker names resolve to the same digest and check the canonical
   GitHub Release and its assets. There is no duplicate legacy GitHub Release.

The alias applies only to the exact configured release, including its prerelease
suffix. Untagged builds and other release versions never receive that alias. Manually
pushing the alias does not trigger another build or deployment. An existing alias
on another commit blocks publication; retries never move it. Platform-image
digests may have been built before that check, but named images and charts have not.

## Version names

Use unpadded `YYYY.M.D-alpha` for alpha releases, which update `latest`.
Use unpadded `YYYY.M.D` for stable releases, which update `stable`.
There are no numbered canonical prereleases, beta/RC tags or hotfix suffixes.
Only the temporary legacy compatibility alias keeps its old numbered format.

The date distinguishes releases: publish at most one alpha and one stable per
UTC day. A retry reuses the same tag and commit; a different release uses a new
date, not an incremented suffix or a moved tag. Cut release branches as usual;
daily fixes do not create new ones.

## January

Stop issuing legacy aliases and clear the two compatibility settings. The
workflow only emits them for 2026 dates. Keep historical tags, images and chart
packages for pinned installations and rollback. The temporary alias steps can
then be removed from the workflow—there is no library or registry to migrate.
