# Loan amortisation modelling blueprint

Status: normative design record for the Loan Amortisation Modelling epic (#24).
The calculation contract in `docs/loans/calculation-contract.md` is the
authoritative source for individual financial decisions.

## Goal

Turn loan accounts into a forecasting and modelling surface with real payoff
dates, daily actual/365 interest, variable-rate handling, offset-aware output,
and explicitly shared what-if scenarios.

## Boundaries

- Contracted schedules are distinct from live or hypothetical projections.
- Read, API, and render paths are read-only. Explicit rebuild jobs own schedule
  materialisation and replacement.
- Financial loops use `BigDecimal`; currency rounding occurs only at defined
  output or charge boundaries.
- A converged schedule ends at exactly zero and never produces a negative
  balance.
- Offset-derived output is visible only when every user who can see the loan
  can also see the linked offset account.
- Scenarios are shared household artifacts; attribution is not authorization.

## Calculation decisions

The calculator uses actual elapsed calendar days over a 365 denominator, daily
end-of-day interest-bearing balances, monthly charge points, and a single
unrounded accumulation before charge-point rounding. Rate accrual and payment
re-amortisation use separate clocks: a rate affects accrual from its effective
date, but changes the minimum payment from the next contractual payment date.

Same-day processing is: accrue through the day; apply extra repayment; apply
offset movement; charge interest and make the scheduled payment; then apply
re-amortisation for the next period. Interest-bearing balance is
`max(0, balance - offset)`.

The full C1-C16 decision table and demonstrating tests live in
`docs/loans/calculation-contract.md`. Any change to these decisions requires a
contract update, targeted regression coverage, release-version review, and
external reconciliation review where applicable.

## Evidence gates

- G1: contract approval and machine-verifiable test traceability.
- G2: real, approved, de-identified lender reconciliation.
- G3: rebuild, monitoring, and rollback evidence.
- G4: offset visibility and adversarial authorization coverage.
- G5: scenario authorization and concurrency coverage.
- G6: accessible chart and data alternative.
- G7: API/CSV caching, sharing, and versioning review.
- G8: issue, PR, scope, and milestone consistency.

No characterisation suite substitutes for G2. A real statement is handled
outside the repository; only aggregate residuals, explanations, and approval
metadata are recorded here.

## 17.5 Definition of done

Every change in this epic is complete only when the following evidence is
available in the issue or pull request:

1. The change maps to one issue and one reviewable pull request.
2. The relevant calculation-contract rows and named tests are linked, and the
   full test suite passes.
3. Financial changes include targeted boundary, rounding, sign, and
   conservation tests; mutation evidence is recorded where the gate requires
   it.
4. Fixtures and generated test data use documented token-shaped allowlists and
   pass internal-consistency checks before the application suite runs.
5. Security-sensitive changes include domain/service-layer authorization tests
   and adversarial cases, not only controller or UI coverage.
6. Performance-sensitive changes include production-shaped workload details,
   p95/p99 measurements, and the applicable release threshold.
7. The issue, design record, API documentation, release evidence, and gate
   status agree; unresolved external approvals are named explicitly rather
   than represented as passing evidence.
