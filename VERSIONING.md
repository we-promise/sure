# Versioning

This document describes how versioning is done for Sure.

The versioning scheme described here is valid only from version `0.8.0` onward.
Earlier versions may have followed different rules and should not be interpreted
through this document.

## Scheme

Sure uses `X.Y.Z` versions with optional prerelease suffixes:

- Stable release: `X.Y.Z`
- Alpha release: `X.Y.Z-alpha.N`
- Beta release: `X.Y.Z-beta.N`
- Release candidate: `X.Y.Z-rc.N`

The canonical version is stored in `.sure-version`. The Helm chart version in
`charts/sure/Chart.yaml` must match it in both `version` and `appVersion`.

## Version Progression

The `scripts/cut-version` script applies these rules:

- Point release, default: `X.Y.Z` becomes `X.(Y+1).0`.
- Fix release, `--fix`: `X.Y.Z` becomes `X.Y.(Z+1)`.
- Alpha release, `--alpha`:
  - `X.Y.Z` becomes `X.(Y+1).0-alpha.1`.
  - `X.Y.Z-alpha.N` becomes `X.Y.Z-alpha.(N+1)`.
  - Beta and RC versions cannot be converted back to alpha.
- Beta release, `--beta`:
  - `X.Y.Z` becomes `X.(Y+1).0-beta.1`.
  - `X.Y.Z-alpha.N` becomes `X.Y.Z-beta.1`.
  - `X.Y.Z-beta.N` becomes `X.Y.Z-beta.(N+1)`.
  - RC versions cannot be converted back to beta.
- Release candidate, `--rc`:
  - `X.Y.Z` becomes `X.(Y+1).0-rc.1`.
  - `X.Y.Z-alpha.N` or `X.Y.Z-beta.N` becomes `X.Y.Z-rc.1`.
  - `X.Y.Z-rc.N` becomes `X.Y.Z-rc.(N+1)`.

## Release Process

Use `scripts/cut-version` to cut a version. The script:

1. Validates `.sure-version`.
2. Computes the next version from the selected release type.
3. Tags the current version as `v<CURRENT_VERSION>`.
4. Pushes that tag.
5. Updates `.sure-version` and `charts/sure/Chart.yaml` to the next version.
6. Commits the version bump.
7. Pushes the current branch.

Useful flags:

- `--alpha`, `--beta`, `--rc`, `--fix`: choose the release type. At most one may
  be provided. With none provided, the script cuts a point release.
- `--dry-run`: print what would happen without changing files, tags, commits, or
  pushes.
- `--allow-dirty`: allow running with a dirty worktree.
- `--no-tag`: skip tag creation and tag push.
- `--no-commit`: skip committing the version bump.
- `--no-push`: skip pushing tags and branches.
- `--verbose` or `-v`: enable debug logging.
