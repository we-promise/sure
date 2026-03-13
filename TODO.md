# TODO - Gimli Security Pentest (sure) 2026-03-13

## Context

Pentest of `dgilperez/sure` (Ruby on Rails, PostgreSQL, OAuth2 — web app + mobile API + webhooks).
Last pentest: 2026-03-02 (PENTEST-2026-03-02.md — 16 fixes applied).
Scope: find new vulnerabilities since last pentest, check if previous fixes held, focus on mobile API and webhooks.

Previous pentest report: `docs/security/PENTEST-2026-03-02.md` (read it to avoid re-reporting fixed issues).

## Active

- [x] Recon: Read previous pentest (docs/security/PENTEST-2026-03-02.md), map current codebase structure, identify any new code since last scan
  - Focus: new files/routes added, changes to auth, API endpoints, webhooks
  - Check Gemfile for dependency CVEs (run `bundle audit` if available, or check manually against known CVEs)
  - Check package.json/yarn.lock for JS dependency CVEs
  - **Result**: All 12 previous open findings (F-01 through F-12) verified as FIXED. 0 dependency CVEs.

- [x] Auth & Session Security
  - OAuth2 flow: check for PKCE, state param validation, redirect_uri whitelist
  - Session fixation, session timeout, concurrent session limits
  - Password reset tokens: entropy, expiry, single-use
  - Account lockout / brute force protection
  - **Result**: Found NEW-01 (CRITICAL) - Password change without current password verification

- [x] Mobile API Security
  - JWT validation: alg=none, weak secret, expiry
  - Check `Api::V1::BaseController` auth logic (authenticate_oauth, revoked? check)
  - API rate limiting per endpoint
  - CORS configuration for mobile origins
  - Mass assignment protection in API controllers
  - **Result**: Verified secure. F-01, F-06 fixes confirmed working.

- [x] Webhook Security
  - Signature verification on all incoming webhooks
  - Replay attack protection (timestamp window)
  - SSRF via webhook URLs (if any outbound webhooks)
  - **Result**: Verified secure. Plaid and Stripe signature verification in place.

- [x] Input Validation & Injection
  - SQL injection scan: check raw SQL, string interpolation in queries
  - XSS: unescaped user content in views
  - IDOR: resource ownership checks across controllers
  - File upload: type validation, path traversal, storage security
  - **Result**: Found NEW-02 (CRITICAL) SQL injection via ORDER BY, NEW-03 (MEDIUM) unsafe SQL patterns

- [x] Secrets & Configuration
  - Check for secrets in git history: `git log --oneline -100` + `git show` spot checks
  - Check credentials.yml.enc, master.key handling
  - Env vars: any hardcoded in code vs proper Rails credentials?
  - Check `.env` files committed
  - **Result**: Verified secure. master.key required, secrets properly gitignored.

- [x] Write pentest report
  - Save to: `docs/security/PENTEST-2026-03-13.md`
  - Format: severity (CRIT/HIGH/MED/LOW/INFO), CVE refs if applicable, fix recommendation
  - Apply any [safe] fixes directly (dependency upgrades, config fixes)
  - Leave [review] items documented but not applied
  - Append summary to REPORT.md
  - **Result**: ✅ Complete - docs/security/PENTEST-2026-03-13.md written

## Done
