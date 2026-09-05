# Triage: we-promise/sure PR #1775 ("Feat/loans overview new insights")

Source: https://github.com/we-promise/sure/pull/1775 (upstream repo, not this fork).

## ⚠️ Sourcing & confidence — read this first

This session has **no verified access** to `we-promise/sure`: it's a different
GitHub owner than this fork (`jaysbeekay/sure`), and attaching it was refused
("cross-tier adds are not supported"). Direct requests to
`api.github.com/repos/we-promise/sure/...`, and even the plain PR HTML page and
`.diff`/`.patch` endpoints, all return 403 ("GitHub access to this repository
is not enabled for this session") when hit directly.

The only thing that returned data was the `WebFetch` tool, which does **not**
give raw page content — it renders the page and then runs a separate, smaller
model over it to answer a prompt. Every detail below (reviewer usernames, bot
names, specific numbers like the suggested `term_months` cap, class names like
`stroke-zinc-700`, the "80%" coverage figure, dates, the exact YAML
indentation claim) came from that paraphrase, with no second source to
cross-check it against. **None of it should be treated as confirmed** until
someone with real access to `we-promise/sure` (API, or this session re-run
with that repo as its initial source) verifies it against the actual PR
timeline and diff.

The one section below that *is* independently verified is "Current state in
this fork" — that came from grepping this repository's actual files, not from
WebFetch.

Given that, treat everything in "PR summary" through "Test coverage" as a
**lead to verify, not a finding to act on**.

## PR summary (unverified — see above)

Adds editable loan fields (`down_payment`, `insurance_rate`, `insurance_rate_type`,
`start_date`) plus derived insights: remaining loan amount, initial leverage, and a
monthly payment breakdown by principal/interest/insurance, with a cached amortization
schedule and a redesigned overview UI.

## Status at triage time (unverified — see above)

- Open, stale: no substantive commits since May 15; last activity is maintainer
  nudges.
- Unresolved merge conflicts against base (raised Aug 4, repeated Aug 7).
- `sure-admin` bot posted a backlog-cleanup notice (Aug 7): auto-close in one week
  if the author doesn't respond.
- CI: failing checks / conflicts blocking merge.

## Feedback, by category (unverified — see above)

### 1. Correctness & security (must-fix)

- **P1 DoS** (`superagent-security`, Jun 14): `term_months` is unbounded, so
  `generate_amortization_schedule`'s `months.times` loop can be driven arbitrarily
  large by an authenticated user. Fix: validate an upper bound (e.g.
  `validates :term_months, numericality: { less_than_or_equal_to: 600 }`, 50 years)
  plus a guard clause before generating the schedule.
- **Stale cache key** (@jjmata): the `amortization_schedule` cache key doesn't
  change when `Account#original_balance` changes, so edits can serve a stale
  schedule. Fix: include the balance (or an updated-at/version marker) in the
  cache key.
- **Functional regression** (@jjmata): the real account balance display was
  replaced by the new amortization progress ring instead of shown alongside it.
- **Missing navigation** (@jjmata): the "Edit loan details" link was removed with
  no replacement entry point.

### 2. Data model / schema

- `down_payment` is missing `precision: 15, scale: 2` (@jjmata; also flagged by
  CodeRabbit as a migration-safety issue).
- A `NOT NULL` column is added with no backfill strategy (CodeRabbit).
- Unrelated schema drift: holdings-snapshot and trades columns/indexes are
  showing up in the diff — `schema.rb` needs a clean regeneration off a rebased
  `main`, with the unrelated changes dropped (@jjmata, repeated by CodeRabbit on
  later scans).

### 3. Code style / conventions

- `set_default_start_date`, `generate_amortization_schedule`, and
  `payment_date_for` are public callback-style helpers that should be `private`
  (@jjmata) — matches this codebase's own "fat models, encapsulated" convention.
- Raw Tailwind utility classes (e.g. `stroke-zinc-700`) bypass the design system
  instead of using its functional tokens (CodeRabbit; also tracked by the
  `sure-design` bot, resolved 7/7 prior flags by Aug 4 with the SVG progress
  visualization rewritten onto the `donut-chart` controller).
- A hardcoded `default: v[:long]` i18n fallback remains in the form despite the
  locale entries existing — still open as of the Aug 4 `sure-design` pass
  (violates this repo's "all user-facing strings via `t()`" rule).

### 4. i18n / copy

- "Edit loan details" is hardcoded in English with no translation entry.
- Wrong terminology: "refunded" should read "repaid" in the English locale.
- French locale: `rate_types.adjustable` is left untranslated.
- YAML indentation is inconsistent: the `years` block uses 4 spaces vs. 2 spaces
  for `months` — normalize to the repo's 2-space convention.

### 5. Test coverage

- CodeRabbit flagged docstring coverage at 0% against an 80% bot threshold. This
  repo's own convention (`CLAUDE.md`) is to default to *no* comments unless the
  WHY is non-obvious, so that threshold shouldn't be chased mechanically — but
  the underlying ask (more confidence in the new logic) is legitimate: add
  `loan_test.rb` coverage for the new fields and the DoS guard boundary, plus
  system-test coverage for the new overview insights.

## Current state in this fork (jaysbeekay/sure) — verified directly against this repo's files

- `main` already has a simpler `Loan` model (`term_months`, `interest_rate`,
  `rate_type`) with **no** `down_payment`, `insurance_rate`,
  `insurance_rate_type`, or `start_date` — PR #1775's feature has not been
  merged here.
- This fork's four open PRs (#1–#4) build payoff-projection / what-if-modeling
  UI on top of the existing simple model — a separate line of work from #1775.
- None of #1775's flagged defects currently exist in this repo's code, so there
  is nothing here today that needs a code fix for them.

## Remediation plan (contingent on verifying the feedback above first)

This is a plan for *if* the unverified feedback above checks out — not a
confirmed action list. Before anyone works from it: pull the real PR #1775
timeline and diff (via `gh`/GitHub API from a session or account with access
to `we-promise/sure`) and confirm each item actually appears. Ordered for
whoever picks this up next, whether that's upstream (if #1775 is rebased and
resubmitted) or this fork (if the feature gets adopted here):

1. Rebase onto current `main`; resolve merge conflicts; regenerate `schema.rb`
   cleanly, dropping the unrelated holdings/trades diff.
2. Cap `term_months` at the model-validation layer and add a guard clause in
   `generate_amortization_schedule` (fixes the P1 DoS).
3. Add `precision: 15, scale: 2` to `down_payment`; use a default and
   backfill before enforcing `NOT NULL`. If a temporary nullable phase is
   required, backfill existing rows and add a follow-up `NOT NULL` constraint.
4. Restore the actual account balance alongside the new progress ring; restore
   an "Edit loan details" entry point.
5. Fix the `amortization_schedule` cache key to invalidate on balance change.
6. Make `set_default_start_date`, `generate_amortization_schedule`, and
   `payment_date_for` private.
7. Replace raw Tailwind classes with `sure-design-system.css` tokens.
8. i18n cleanup: remove the hardcoded `default: v[:long]` fallback and the
   hardcoded "Edit loan details" string (route both through `t()`); fix
   "refunded" → "repaid"; translate the remaining French `rate_types.adjustable`
   entry; normalize YAML indentation to 2 spaces.
9. Add `loan_test.rb` coverage for the new fields and the DoS boundary, plus a
   system test for the overview insights.

## Decision: leave #1775 to upstream

Decided by @jonathan.kaiser (2026-09-03): leave upstream PR #1775 to its own
maintainers. This fork will not port or re-implement its "loans overview new
insights" feature. This document stands only as an (unverified — see above)
triage record in case that changes later; no further implementation work is
planned from it.
