# Sure release versioning

Use unpadded `YYYY.M.D-alpha` for alpha releases and `YYYY.M.D` for stable releases.
The date is the actual UTC release date. Git tags include `v`; Docker tags and
chart versions do not. There are no numbered canonical prereleases, beta/RC tags
or hotfix suffixes.

Release tags supply the canonical version to every build. A retry reuses the same
tag and commit, even after midnight. Publish at most one alpha and one stable per
UTC day; a different release uses a new date, not an incremented suffix or a moved
tag. Cut release branches as usual; daily fixes do not create new ones.

## Build metadata

`.sure-version` is generated build metadata, ignored by Git. The Docker workflow
writes it into the build context before packaging; Rails, Sentry and backups
continue reading that immutable file inside the image. Source checkouts without
it use `0.0.0-dev.<commit_sha>` (or `0.0.0-dev.unknown` when unavailable). Local Docker
builds can generate the file explicitly to label their image; without it they are
dev builds.

Manual builds selecting a canonical tag retain its version but remain
non-releases: they publish only the selected commit's SHA image tag when requested.
Untagged Docker builds use the original workflow run's UTC date (`YYYY.M.D-alpha`);
retries retain that date. They keep SHA tags without promoting `stable` or `latest`.
Scheduled builds additionally publish floating `nightly` and unpadded
`YYYY.M.D-nightly` Docker tags (for example, `2027.1.1-nightly`), using that same
original UTC run date on retries. Existing images and tags are not deleted, and
no retention or cleanup policy is changed.

Desktop and mobile release builds derive their versions from the release tag.
Standalone mobile branch builds retain their explicit pubspec version. Release
chart packages are stamped from the release tag; chart-only releases select an
existing immutable image via the `app_version` dispatch input (or an explicit
Chart.yaml appVersion for chart-tag pushes). The checked-in chart has development
defaults; it does not claim to be a dated release. No version write-back commits
or channel-state files are needed.

## Releasing

1. Generate the canonical tag from the UTC build day, once, when starting the release:
   `tag="v$(date -u +%Y.%-m.%-d)-alpha"` (omit `-alpha` for stable).
2. Push only that canonical tag at the intended release commit. Reuse it on retries,
   even after midnight. No source date edit or legacy alias bump is needed.
3. Verify the versioned Docker image, the canonical Helm package, and the single
   GitHub Release with its mobile and desktop assets. All artifacts must identify
   the selected canonical version and commit.

## Floating Docker channels

**Floating Docker channel promotion is temporarily paused.** Neither alpha nor
stable releases update `latest` or `stable` while we validate the CalVer rollout.
Existing channel tags stay on their previous images. Test using explicit CalVer
image tags. Re-enabling channel promotion requires a separate workflow change
after validation; compatibility cleanup does not resume it. Nightly tags and
release/deployment jobs are unchanged.

## Historical compatibility aliases

The October–December 2026 transition began with the `v0.7.7-alpha.3` compatibility
alias. Eligible releases could publish a legacy Git tag, Docker alias, and Helm
package alongside their canonical CalVer artifacts. From January 2027, release
automation no longer creates those aliases or compatibility packages.

Keep historical tags, images, chart packages, and releases for pinned installations
and rollback. Legacy `v0.*` tag pushes remain no-ops, and Rails continues accepting
legacy release versions in release-highlight history. There is no library or
registry migration and no historical artifact deletion.
