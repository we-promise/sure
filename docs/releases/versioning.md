# Calendar versions and compatibility aliases

Sure uses `YYYY.M.D` (UTC release date, without zero padding). The first canonical
release is `v2026.10.31`, with `v0.7.6` as its compatibility alias. Both Git tags
identify one commit. The app, desktop, release notes and image metadata use the
canonical version. Git tags include `v`; Docker tags and chart versions do not.

## Channels and fixes

- A clean date is stable, published from the branch named in `.sure-release-branch`.
- `-alpha` or `-alpha.N` publishes `latest` and deploys the demo. The optional count
  can track alphas within a cycle; dates and counts are set explicitly.
- `-beta`, `-beta.N`, `-rc`, and `-rc.N` are prereleases without a floating image channel.
- Hotfixes land on `main`, are tested as alphas, then are cherry-picked to the
  maintained release branch. Give the stable fix its actual publication date,
  not a `-hotfix.*` suffix. Keep the branch name unchanged for that maintenance line.
- Never move or overwrite a published Git tag. There is one stable release per UTC
  date under this policy. A second same-day stable release needs an agreed naming
  extension before publication; neither `-1` nor build metadata is a newer patch.
- A newer-date alpha can sort above an older stable release. Channel selection is
  explicit; version ordering alone must not switch users between stable and alpha.

## First release checklist

1. Merge the automation change, then cherry-pick it to the existing
   `v0.7.6-release-branch` together with the reviewed release contents. A merge to
   `main` alone does not put the change into that already-cut release branch.
2. Verify `.sure-version`, chart `version` and chart `appVersion` are `2026.10.31`.
   `.sure-release-branch` must still name `v0.7.6-release-branch`. Test the exact
   candidate and inspect generated notes against the previous canonical stable tag.
3. Push **only** `v2026.10.31` at the approved release-branch commit. The workflow
   verifies branch membership and creates/verifies `v0.7.6` without force-pushing.
   A pre-existing alias on another commit fails before artifact publication.
4. The single build publishes Docker `2026.10.31`, `0.7.6`, and `stable` from one
   multi-architecture manifest. Check that all three resolve to the same digest.
5. Helm publishes chart versions `2026.10.31` and `0.7.6`, both with canonical
   `appVersion: "2026.10.31"`. These are distinct packages sharing an app image.
6. Verify the one GitHub release at `v2026.10.31`, its assets, desktop version,
   mobile marketing version and the exact-tag in-app release notes. There is no
   duplicate GitHub Release at the legacy tag; use the canonical release link.
7. Existing stable-environment approval and deployment prerequisites still apply.
   This PR does not publish tags, release assets, or deploy anything by itself.

Manual pushes of the compatibility tag do not build, publish, bump versions or
trigger deployments. Retries accept an existing alias only at the same commit,
including annotated tags. Publish retries may rebuild artifacts; the alias and
canonical Docker tags are always assigned together in the same manifest operation.

## Remaining transition and January cutover

For subsequent stable releases through December, explicitly add the mapping from
canonical date to the next unused `0.7.x` patch version in
`config/release_aliases.json`. Do not guess aliases from the date or reuse an alias.
Update `.sure-version` and `charts/sure/Chart.yaml` together. At a new release-cycle
branch cut, update `.sure-release-branch`; daily hotfix dates do not create branches.
CalVer does not run the legacy automatic prerelease-counter bump workflow.

From January 2027, issue only CalVer versions. The resolver rejects compatibility
mappings for 2027 and later. Keep historical tags, images, chart packages and the
mapping history for pinned installations and rollback. A legacy Docker pin sees
the canonical version inside the app because both tags run identical bytes.

The shared Flutter build stamps the numeric date as its marketing version (matching
TestFlight's existing base-version convention). Store build numbers remain separate;
this migration does not reset them. macOS/Flutter packaging and store acceptance
must be checked on their respective release runners; Linux Rails tests do not prove
platform packaging succeeds.
