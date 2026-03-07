# Security Pentest Report — Sure Application

## Engagement: 2026-03-02 (Gimli Pentest)

**Scope**: Full application pentest — authentication, authorization, input validation, configuration, secrets
**Previous**: 2026-03-01 pentest covered auth/session (see `docs/security/PENTEST-2026-03-01.md`)
**Full report**: `docs/security/PENTEST-2026-03-02.md`

### Results Summary

| Metric | Count |
|--------|-------|
| **Fixed** | 16 |
| **Open (review needed)** | 12 |
| **Verified secure** | 30+ areas confirmed |
| **Test regressions** | 0 |

### Fixed (16 findings)

| # | Finding | Severity |
|---|---------|----------|
| FIX-01 | Session fixation on non-MFA login paths | HIGH |
| FIX-02 | API login missing active user check | HIGH |
| FIX-03 | API signup bypasses registration closure | HIGH |
| FIX-04 | Refresh token doesn't check active status | MEDIUM |
| FIX-05 | Stored XSS via markdown rendering (Redcarpet filter_html) | HIGH |
| FIX-06 | Stored XSS via changelog html_safe | HIGH |
| FIX-07 | Unsafe constantize in import mappings | HIGH |
| FIX-08 | Open redirect via store_return_to | MEDIUM |
| FIX-09 | Sidekiq Web UI default credentials | HIGH |
| FIX-10 | Lookbook exposed in production | MEDIUM |
| FIX-11 | API error message information disclosure (9 files) | MEDIUM |
| FIX-12 | Invite codes missing admin authorization | MEDIUM |
| FIX-13 | Password reset doesn't invalidate sessions | MEDIUM |
| FIX-14 | Timing-unsafe API key comparison | MEDIUM |
| FIX-15 | Timing-unsafe backup code comparison | MEDIUM |
| FIX-16 | require_master_key not enforced | LOW |

### Open — Requires Product/Architecture Decision (12 findings)

| # | Finding | Severity | Priority |
|---|---------|----------|----------|
| ~~F-01~~ | ~~API login bypasses AuthConfig (SSO-only mode)~~ | ~~HIGH~~ | ✅ Fixed (2026-03-07) |
| ~~F-02~~ | ~~CORS wildcard on sensitive endpoints~~ | ~~HIGH~~ | ✅ Fixed (2026-03-07) |
| ~~F-07~~ | ~~Unsafe constantize in account_import.rb~~ | ~~HIGH~~ | ✅ Fixed (2026-03-07) |
| F-03 | Content Security Policy disabled | MEDIUM | Short-term |
| F-04 | Web sessions never expire | MEDIUM | Short-term |
| F-05 | DNS rebinding protection disabled | MEDIUM | Short-term |
| ~~F-06~~ | ~~No OTP rate limiting on API login~~ | ~~MEDIUM~~ | ✅ Fixed (2026-03-07) |
| F-08 | SSRF via base_url in Mercury/Lunchflow | MEDIUM | Medium-term |
| F-09 | CSV injection in data exports | MEDIUM | Medium-term |
| F-10 | Open redirect in accountable_resource.rb | MEDIUM | Medium-term |
| F-12 | rack-mini-profiler in production | MEDIUM | Medium-term |
| F-11 | MFA setup/disable without re-auth | LOW | Low |

### Files Modified (22)

See `docs/security/PENTEST-2026-03-02.md` for the complete file change list.
