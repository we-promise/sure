# CalVer transition: October–December 2026

The next release is **`v2026.10.28`**, with **`v0.7.6`** as a temporary
compatibility alias. Release tags supply the canonical date to every build.
Git tags include `v`; Docker tags and chart versions do not.

`.sure-version` is generated build metadata, ignored by Git. The Docker workflow
writes it into the build context before packaging; Rails, Sentry and backups
continue reading that immutable file inside the image. Source checkouts without
it use `0.0.0-dev` (with the commit SHA available separately). Local Docker builds
can generate the file explicitly to label their image; without it they are dev builds.

Tagged releases derive their version from the tag, so retries retain the same
identity. Untagged Docker builds use the original workflow run's UTC date and
run number (`YYYY.M.D-alpha.N`); retries retain both. They keep the existing SHA/
nightly registry tags and do not promote `stable` or `latest`.

Desktop and mobile release builds also derive their versions from the release
tag. Standalone mobile branch builds retain their explicit pubspec version.
Release chart packages are stamped from the release tag; chart-only releases
select an existing image through Chart.yaml appVersion. No version write-back
commits or channel-state files are needed.

## Releasing

1. Bring this change to the existing `v0.7.6-release-branch` before release.
   Keep the current process: fixes land on `main`, are tested as alphas, then
   are cherry-picked to the maintained release branch.
2. Choose the actual UTC release date for the canonical tag.
   In `publish.yml`, set `COMPATIBILITY_RELEASE` to that date and
   `COMPATIBILITY_VERSION` to the next unused legacy version.
3. Push only the canonical tag. The workflow creates/verifies the legacy Git
   tag without force, publishes both Docker names against one manifest, and
   packages both Helm versions pointing to the canonical image.
4. Verify both Docker names resolve to the same digest and check the canonical
   GitHub Release and its assets. There is no duplicate legacy GitHub Release.

The alias applies only to the configured stable date, never its alphas. Manually
pushing the alias does not trigger another build or deployment. An existing alias
on another commit blocks publication; retries never move it. Platform-image
digests may have been built before that check, but named images and charts have not.

## Version names

Use unpadded `YYYY.M.D`, optionally followed by `-alpha` or `-alpha.N` (also
beta/RC). A clean date updates `stable`; alpha updates `latest`; beta/RC update
neither floating channel. Dates and optional counters are set explicitly, not
auto-bumped. Cut release branches as usual; daily fixes do not create new ones.
There is no `-hotfix.*` suffix. This change does not introduce a same-day stable
respin naming scheme.

## January

Stop issuing legacy aliases and clear the two compatibility settings. The
workflow only emits them for 2026 dates. Keep historical tags, images and chart
packages for pinned installations and rollback. The temporary alias steps can
then be removed from the workflow—there is no library or registry to migrate.
