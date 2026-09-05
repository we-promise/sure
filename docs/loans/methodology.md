# Loan reconciliation methodology

Status: **not reconciled.** The committed fixture is synthetic. Gate G2 (#11)
is open.

## Why the fixture is synthetic

A lender statement is personal financial data. So is anything derived from one:
drawdown amounts, running balances, charge dates and rate history together
identify a borrower even with names, account numbers and BSBs removed. None of
it belongs in this repository, which is a public fork.

`test/fixtures/loan_reconciliation.csv` is therefore constructed, not observed.
It reproduces the *shape* of a home-loan statement — drawdown, monthly interest
charges, extra repayments between charges, and one rate change falling
mid-cycle — with arithmetic that is exact by construction:

- every movement sums to the stated running balance;
- every rate movement is declared by a `rate_change` row;
- each interest charge is the piecewise actual/365 accrual over the balance and
  rate segments in its own window, rounded once at the charge point.

`test/models/loan/reconciliation_test.rb` asserts all three, plus a structural
de-identification guard: the file may contain only ISO dates, the four known
category tokens, and two-decimal numerics. The guard is an allowlist because a
denylist of names would have to write those names into the test.

## Running the real reconciliation

The real statement work happens **outside the repository**, and only its
findings come back:

1. Hold the statements and any normalised export outside the working tree, and
   outside any directory that is committed, indexed or backed up to a shared
   service.
2. Reconcile each interest charge against `Loan::InterestAccrual` over the
   charge window, using the balance and rate segments that actually applied.
3. Record, in this document: the number of charges compared, the residual
   distribution, and a stated reason for every non-zero residual. Record no
   amounts, dates, balances or rates from the source.
4. Where a residual is explained by an offset balance, say so and mark it
   unproven rather than tolerated — an offset saving quoted by the lender is
   the lender's own figure, not an independent check of ours.

## Independent reference

The fixed / no-offset reference is written from the formula, independently of
the simulator:

    interest = days × max(0, balance − offset) × annual_rate / 100 / 365

Interest accumulates at full precision and is rounded once at the charge point.
`Loan::ReconciliationTest`, in "independent actual/365 reference agrees with
Loan::InterestAccrual", compares that reference to the engine. A reference
calculation that is never compared to the implementation demonstrates nothing,
so the comparison — not the formula — is the evidence.

## Outstanding before G2 can be signed off

- **The statement reconciliation itself.** Nothing in this repository currently
  compares the engine to a real lender charge.
- **Mid-cycle rate changes.** The engine applies one rate per payment period,
  so a rate effective mid-cycle is applied retroactively across the whole
  window. A statement covering such a period cannot reconcile until the accrual
  and re-amortisation clocks are separated (contract C7/C8).
- **Offset movement.** Daily offset reconciliation needs the linked account's
  balance history. Until that is available, offset cases are out of scope for
  sign-off rather than tolerated within it.
- **Finance review.** No reviewer has signed off any figure in this document.

No production release approval is granted by this document.
