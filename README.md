# DS::Alert visual reference (PR #1731)

Screenshots backing the visual-changes section of #1731. Captured via Playwright
on `upstream/main` (before) and `feature/ds-alert-extension` (after) with the
Rails dev server in self-hosted mode and a logged-in admin user. Each PNG is a
DOM-element-level crop, not a full-page shot.

This branch is unmerged on purpose — it only exists to host raw image URLs that
the PR description points at. Safe to delete after #1731 is reviewed and merged.

## Layout

- `screenshots/before/{light,dark}/*.png` — `upstream/main` (raw Tailwind palette).
- `screenshots/after/{light,dark}/*.png` — PR branch (semantic alpha-modifier tokens, body slot).

## Coverage

Lookbook (component-isolated):
- `lookbook-default-{info,success,warning,error}` — base variants, both before/after.
- `lookbook-with-title`, `lookbook-with-body-slot` — after-only (new shapes added by this PR).

Real callsites (in-context):
- `api-key-new` — `settings/api_keys/new.html.erb` Security Warning. Before relies on `bg-warning-50`/`text-warning-700` which compile to nothing (no `--color-warning-50` token); after uses `bg-warning/10` modifier on the `--color-warning` theme colour.
- `hostings-eodhd`, `hostings-alpha-vantage` — `settings/hostings/_eodhd_settings.html.erb` and `_alpha_vantage_settings.html.erb` rate-limit warnings. Before uses `bg-amber-50` raw palette (does compile); after uses `bg-warning/10` for token-system consistency.
- `hostings-yahoo-finance` — `settings/hostings/_yahoo_finance_settings.html.erb` connection-failed alert. After-only because the alert only renders when the upstream Yahoo Finance endpoint is unhealthy at capture time, and the before run happened to land while it was healthy. Same `bg-amber-50` chrome as alpha_vantage / eodhd in the before state.
