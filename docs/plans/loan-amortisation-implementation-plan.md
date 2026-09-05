# Loan amortisation modelling: implementation plan

Status: analysis only; no production code changes are included in this plan.

## Current baseline

The checkout already contains a first-generation amortisation implementation:

- `Loan::AmortizationSchedule` calculates a contracted monthly schedule and
  supports fixed and variable rates.
- `Loan::AmortizationMath` centralises decimal rounding and final-payment
  settlement.
- `LoanAmortization` stores materialised rows; `LoanAmortizationRebuildJob`
  rebuilds them asynchronously.
- `Loan::PayoffProjection` models the current account balance and extra-payment
  what-if paths, but is currently fixed-rate and monthly-granularity.
- Existing Minitest coverage includes variable-rate boundaries, month-end date
  clamping, zero interest, final settlement, persisted schedule freshness, and
  payoff projections.

The working tree has an unrelated modification to `.ruby-version`; it must be
preserved. The referenced design blueprint and delivery-breakdown files are not
present in this checkout, so issue #24 and its child issue bodies are the
current planning inputs until those documents are restored or attached.

## Required order of work

1. **L0 / #6 — approve the calculation contract.** Create the decision record
   before changing calculation code. It must resolve C1–C16, including actual/365,
   payment timing, extra-payment timing, the two rate clocks, same-day event
   ordering, rounding, final payment, offset floor/forward-offset semantics,
   scenario semantics, algorithm-version release/rollback, and the shared-input
   visibility policy. Each decision needs one demonstrating test. Start the
   privacy-approved process for a de-identified lender statement; the statement
   is required for G2 and cannot be replaced by characterisation tests.
2. **L1 / #7 — stabilise the loan page vocabulary and navigation.** This is UI
   only and can proceed independently, but should use the L0 terminology for
   payoff date, remaining balance, and schedule labels. Cherry-pick only the
   schedule Turbo Frame fix from the superseded work.
3. **L2 / #8 — pin the existing calculator before refactoring.** Extend the
   Minitest harness with complete row-level golden masters for fixed, variable
   (two changes), zero-interest, short-term, and month-end-clamped schedules.
   Include continuity and exact-zero invariants, and prove the assertions fail
   on a deliberate one-cent mutation. This protects the refactor but is not a
   financial correctness oracle.
4. **L3 / #9 — extract the resolver-driven simulator with no behaviour change.**
   Keep the public schedule API stable. Pass values and lambdas into the
   simulator; model the four time/balance boundaries, C7/C8 rate clocks,
   immutable results, `:hold`/`:reamortize`, event order, BigDecimal arithmetic,
   and convergence. Do not include offsets, extra repayments, or UI in this
   change.
5. **L3b/L3c / #10 and #11 — introduce daily accrual and prove it externally.**
   Implement piecewise daily accrual with unrounded accumulation and charge-point
   rounding, then ship the versioned migration, batched rebuild task, sampled
   dual calculation, monitoring, rollback rehearsal, and production-shaped
   rollout together. #11 must reconcile a real statement plus rate-change,
   offset, and extra-payment cases and an independent fixed/no-offset reference
   calculation before G2 or deployment.
6. **L4 onward — build on the released engine.** Variable-rate projection (#12)
   follows #9 and the #10/#11 gate; offset policy/domain (#13), origination and
   rate changes (#14), repayment display (#15), and scenarios (#16) follow the
   contract and engine. Charts, comparisons, tables, API/CSV, caching, and
   sharing (#17–#23) follow their domain dependencies and release gates.

## Design constraints for all agents

- Never materialise, delete, or replace schedule rows from a GET, API read, or
  render path. Reads may report stale/missing state and enqueue a rebuild; writes
  and explicit rebuild jobs own mutation.
- Keep the contracted schedule distinct from an in-memory payoff projection.
- Do not merge the superseded `LoanAmortizationSchedule`/`loan_amortization_schedules`
  architecture with the canonical `Loan::AmortizationSchedule`/
  `LoanAmortization` design.
- Use `BigDecimal` and currency precision at calculation boundaries; no Float in
  financial loops.
- Preserve household sharing rules, and test access grant/revoke for every
  offset-derived output before exposing shared account data.
- Use Minitest for behaviour and rswag only for API documentation.

## Validation and handoff protocol

Each issue/PR update should state: files changed, decisions made, tests run and
their environment, unresolved risks/blockers, and the exact next issue that is
unblocked. Attach gate evidence to the relevant issue. A passing characterisation
suite is never reported as lender correctness. Future Rails tests should run in
the repository devcontainer with the project Ruby/Bundler versions and a disposable
database; the host run is currently blocked because PostgreSQL is unavailable.
