# Loan amortisation delivery breakdown

This is the delivery sequence for epic #24. Each issue gets its own reviewable
PR and acceptance evidence. Stacked PRs are allowed only when the parent is
explicitly named and the child diff is independently reviewable.

## Phase 0: decisions and protection

1. **#6 / L0** — approve C1-C16, record the lender-statement owner and privacy
   path, and establish G1.
2. **#7 / L1** — stabilise loan terminology, navigation, labels, and the
   schedule frame fix.
3. **#8 / L2** — complete row-level golden masters and observed-failure
   mutation evidence before refactoring.

## Phase 1: calculation engine and release

4. **#9 / L3** — extract the resolver-driven simulator while preserving the
   public schedule API.
5. **#25 / L17** — implement one coherent change-point model for C6/C7/C8 and
   offset segments; review detection, integration, and contract tests as
   separate acceptance sections, not incompatible implementations.
6. **#11 / L3c** — reconcile fixed/no-offset, rate-change, offset, and extra-
   repayment cases against an approved lender statement and independent
   reference.
7. **#10 / L3b** — ship daily accrual, algorithm versioning, sampled variance,
   rate-limited idempotent rebuilds, monitoring, and rollback evidence together.
8. **#12 / L4** — build variable-rate payoff projection after #25 and the G2/G3
   gates.

## Phase 2: domain

9. **#13** — implement offset linking and shared-input authorization, including
   grant, revoke, bypass, and cross-tenant tests.
10. **#14** — add origination and rate-change management.
11. **#15** — add current minimum repayment and rate-change presentation.
12. **#16** — add extra repayments and shared saved scenarios.

## Phase 3: experience and interfaces

13. **#17-#22** — deliver chart periods, payoff chart, controls, comparison,
    composition, and table enhancements in dependency order.
14. **#23** — deliver scenario API/CSV, response hygiene, caching/sharing
    review, and methodology documentation.

## Release rules

Every issue/PR records changed files, decisions, tests and runtime, unresolved
risks, gate evidence, and the next unblocked issue. Superseded branches are
closed only after each commit has a documented destination and the destination
PR is independently reviewable.
