# CalVer transition: October–December 2026

The next release is **`v2026.10.28`**, with **`v0.7.6`** as a temporary
compatibility alias. `.sure-version` and Helm metadata use the canonical date.
Git tags include `v`; Docker tags and chart versions do not.

Use the actual UTC release date, not a fixed month-end date. If the release
moves to another day, update `.sure-version`, the chart version/appVersion and
`COMPATIBILITY_RELEASE` together before tagging. Keep that date fixed for retries.

## Releasing

1. Bring this change to the existing `v0.7.6-release-branch` before release.
   Keep the current process: fixes land on `main`, are tested as alphas, then
   are cherry-picked to the maintained release branch.
2. Set `.sure-version` and both Helm version fields to the release date.
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
