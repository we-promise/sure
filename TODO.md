# TODO - Claude Code Pentest Queue

## Active

- [ ] Security pentest: dgilperez/sure (bisemanal 2026-03-12)
  - Stack: Ruby on Rails, PostgreSQL, OAuth2
  - Exposure: Web app + mobile API + webhooks
  - Previous pentest: 2026-03-02 (PENTEST-2026-03-02.md — 16 fixes applied)
  - Scope: Full bisemanal pentest
  - Reference skills: ~/.claude/skills/pentest-analysis, ~/.claude/skills/security-auditor
  
  Tasks:
  1. Read previous PENTEST-2026-03-02.md for known issues and regressions to check
  2. Run full recon: routes, endpoints, auth flows, webhooks
  3. Check for new CVEs in Gemfile.lock dependencies (bundle audit)
  4. Test auth: session fixation, CSRF, OAuth2 flows, token validation
  5. Test authorization: IDOR, privilege escalation, missing ownership checks
  6. Test inputs: SQL injection, mass assignment, parameter tampering
  7. Test webhooks: signature verification, replay attacks
  8. Test API endpoints: rate limiting, auth bypass, data exposure
  9. Check secrets: hardcoded creds, env vars in code/logs, git history
  10. Compare findings against previous pentest — regressions?
  
  Output:
  - Write report to docs/security/PENTEST-2026-03-12.md (format: severity CRIT/HIGH/MED/LOW/INFO)
  - List all [FIX-XX] items applied vs items requiring David review
  - Append summary to REPORT.md
  - Mark task [x] in TODO.md when complete
  - Run: openclaw system event --text "TASK_COMPLETE: sure-pentest-2026-03-12" --mode now

