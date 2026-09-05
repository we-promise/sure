# Loan amortisation calculation contract

Status: draft for engineering and product sign-off. This document is the L0
decision record for issue #6. It is normative for the calculator; implementation
must not silently choose a different interpretation.

## Scope and invariants

The contracted schedule is distinct from a live or hypothetical projection.
Schedules may be materialised by an explicit write/rebuild job, but a GET, API
read, or render path must not delete or replace schedule rows. All monetary
calculation uses `BigDecimal` until the currency rounding boundary. Balances
never become negative, and a converged schedule ends at exactly zero.

## Contract decisions

| ID | Decision | Demonstrating test | External verification |
| --- | --- | --- | --- |
| C1 | Interest accrues daily on the end-of-day interest-bearing balance. | `Loan::InterestAccrualTest` constant-balance daily accrual | Required against a lender statement |
| C2 | Day count is actual/365: actual elapsed calendar days divided by 365. Leap-year days use 366 elapsed days over a 365 denominator. | `Loan::InterestAccrualTest` 28/31/366-day cases | Required against a lender statement |
| C3 | Accrued interest is charged at the contractual monthly payment point. | `Loan::SimulatorTest` charge-point event test | Required against a lender statement |
| C4 | A run has four independent boundaries: `starting_balance`, `starting_balance_as_of`, `accrual_start_date`, and `payment_schedule`. A mid-cycle run accrues a stub period to the next contractual payment date. | `Loan::SimulatorTest` stub-period and boundary tests | Required for a lender mid-cycle case |
| C5 | Payment dates are generated one calendar month after the origination/anchor date and then from the prior scheduled date; shorter months clamp the date (Jan 31 -> Feb 28/29 -> Mar 28/29). | `Loan::AmortizationScheduleTest` payment-calendar and month-end tests | Confirm against statement payment dates |
| C6 | An extra repayment takes effect at the end of its own effective date. It applies on an exact payment date or between payments and is not deferred to the next payment. | `Loan::SimulatorTest` same-day and between-payment extra-repayment tests | Required against a lender extra-payment case |
| C7 | A rate change affects accrual from its effective date, including a mid-cycle date. | `Loan::SimulatorTest` accrual-rate boundary test | Required against a lender mid-cycle rate-change case |
| C8 | A rate change changes the minimum repayment from the next contractual payment date, not from the accrual effective date. | `Loan::SimulatorTest` separate accrual/re-amortisation clock test | Required against a lender mid-cycle rate-change case |
| C9 | Same-day events use this fixed order: accrue through the day; apply end-of-day extra repayment; apply end-of-day offset movement; at the payment point charge interest, make the scheduled payment, then apply any re-amortisation for the next payment period. | `Loan::SimulatorTest` pairwise same-day event-order tests | Required where the statement exposes event timing |
| C10 | Rate and repayment changes are effective inclusively at their defined boundary: the accrual clock includes the effective date; the re-amortisation clock uses the first payment date on or after the change. | `Loan::SimulatorTest` effective-date inclusivity tests | Required against a lender rate-change case |
| C11 | `:hold` keeps the contracted payment and shortens/extends the payoff; `:reamortize` recalculates the payment over the remaining original maturity. The contracted schedule itself does not track live balance. | `Loan::SimulatorTest` strategy tests and `Loan::AmortizationScheduleTest` contract regression | No |
| C12 | Interest, principal, and ending balances are rounded to the account currency precision at their defined output/payment boundary; intermediate daily accrual remains unrounded. | `Loan::InterestAccrualTest` rounding test | Required against statement tolerance |
| C13 | Daily interest segments are summed unrounded, then rounded once when monthly interest is charged. | `Loan::InterestAccrualTest` segment-equivalence and charge-point-rounding tests | Required against a lender statement |
| C14 | The final payment uses the remaining balance as principal plus that period's interest and settles the ending balance exactly to zero. | `Loan::AmortizationScheduleTest` zero-interest 33/33/34 and final-row tests | Required against statement final-payment treatment |
| C15 | Interest-bearing balance is `max(0, loan balance - offset)`. Offset cannot create negative interest or a negative balance. | `Loan::InterestAccrualTest` offset equal-to/greater-than-balance tests | Required against a lender offset case |
| C16 | Forward offset is today's linked offset total held flat for future days. No averaging or smoothing is used; the assumption is disclosed in UI and methodology copy. | `Loan::OffsetResolverTest` forward-flat and one-day movement tests | Required against a lender offset case |

## Offset visibility policy

An account can be linked as an offset only when every user who can access the
loan can also access that account. The rule is enforced when linking. Granting
loan access revalidates existing links; revoking offset access invalidates the
link and returns the loan to non-offset calculation with a visible notice.

Offset-derived output is therefore unconditional for users who can see the
loan. Field-level suppression is rejected because payoff dates, interest saved,
and chart deltas can reveal the hidden offset balance by inference.

## Scenario semantics

Scenarios are shared household artifacts. Anyone who can see the loan may edit
or delete a scenario; `created_by_user_id` is attribution, not authorization.
Results are live estimates recalculated from current loan inputs on every view.
The simulation result is not persisted. Persisted scenarios record
`calculator_version` and `last_calculated_at` so support can identify the engine
that produced a quoted result.

## Versioning, release, rebuild, and rollback

The algorithm version is part of schedule identity. A calculation change must:

1. increment the readable algorithm version and schedule signature inputs;
2. deploy the calculation and its row metadata together;
3. run a sampled old/new dual calculation against production-shaped loans and
   review the variance distribution;
4. prebuild schedules in batched, rate-limited, idempotent jobs without relying
   on page views to trigger completion;
5. monitor queue depth, failed rebuilds, stale schedules, and calculation
   variance; and
6. retain the previous calculation/rebuild path long enough to demonstrate a
   rollback before release.

Daily accrual and its version/backfill release are one deployment train. The
characterisation suite may be deliberately re-baselined only after the lender
reconciliation gate has been reviewed line by line.

## Traceability baseline

| Requirement | Status |
| --- | --- |
| FR-102 origination date | planned |
| FR-105 offset account | planned |
| FR-203 rate changes | planned |
| FR-204 current minimum repayment | planned |
| FR-205 rate-change highlighting | planned |
| FR-206 non-convergence state | planned |
| FR-305 daily offset-aware interest | planned |
| FR-306 forward-offset assumption | planned |
| FR-307 offset privacy | planned |
| FR-308 offset movement | planned |
| FR-309 daily accrual | planned |
| FR-310 offset payoff sensitivity | planned |
| FR-302 extra repayments | planned |
| FR-303 saved scenarios | planned |
| FR-401 variable-rate projection | planned |
| FR-404 original payoff date | planned |
| FR-405 rate-change table | planned |
| FR-408 scenario persistence | planned |
| FR-409 scenario comparison | planned |
| FR-501 loan-scoped all-time chart | planned |
| FR-502 payoff chart | planned |
| FR-503 chart modelling controls | planned |
| FR-504 interest/principal composition | planned |
| FR-505 amortisation table enhancements | planned |
| FR-506 scenario API/CSV | planned |
| FR-507 methodology documentation | planned |
| FR-509 accessible chart alternative | planned |
| FR-510 remaining-balance wording | planned |
| FR-511 Overview default tab | planned |

## Gate G1 and remaining approval

G1 is not complete until engineering and product approve this document and its
tests are represented in #8. The actual/365 assumption and C7/C8 timing remain
explicit verify-against-statement items. A de-identified lender statement has
not yet been supplied in this checkout; its owner, privacy approval, and source
must be recorded on #6 before #10/#11 deployment.
