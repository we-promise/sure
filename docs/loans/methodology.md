# Loan reconciliation methodology

Status: **Gate G2 signed.**

| | |
| --- | --- |
| Signed by | Jonathan Kaiser (`jaysbeekay`), repository owner |
| Recorded | 2026-09-07, confirming the closure of #11 on 2026-09-05 was the sign-off |
| Basis | the real statement reconciliation in #65, summarised below |

The signature is recorded here because a gate with no durable record is not a
gate. It was previously inferable only from an issue closure with no closing
comment, and #11's last comment said the opposite.

**What the signature covers:** gross monthly interest for one lender and one
loan, reconciled 43/43 under actual/actual.

**What it does not cover, and was signed in the knowledge of:**

- **Offset accrual is unproven.** The offset side was reconstructed from the
  lender's own disclosed saving, not checked independently, because the
  statements carry no daily offset balances.
- **One lender, one loan.** Nothing here establishes a basis as correct for any
  other lender.
- **The reconciliation predates the per-loan basis** (`day_count_convention`,
  #70) and has not been re-run against it.
- **The C2 disclosure is not built.** See the outstanding list below; this one is
  a hard requirement of #11 rather than a nice-to-have, and it is unmet.

The remaining items below are therefore no longer gate blockers. They are open
work, and the last one should land before daily accrual reaches users.

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

**The fixture is also reconciled against the engine.** Every `interest` row is
charged through `Loan::InterestAccrual` over the window since the previous
charge, with the fixture's own movements walked into a change-point list. The
windows, segments and expected values all come from the fixture, so the test
fails if the engine's segmentation, day count, effective-date inclusivity or
charge-point rounding changes. Observed failing against two deliberate
mutations:

| mutation | expected | produced |
| --- | --- | --- |
| `DAY_COUNT` 365 → 360 | 1695.34 | 1718.89 |
| rate change applied from the window start rather than its effective date | 1694.87 | 1826.40 |

The second is the C7 defect this programme was already carrying, and the fixture
catches it. This is repository evidence, not lender evidence — it does not
discharge G2.

## Real statement reconciliation (#65)

A real lender statement has been reconciled against `Loan::InterestAccrual`,
following the procedure below. Per the de-identification rule, no amounts,
dates, balances or rates from the source appear here.

| basis | charges reconciling within one cent |
| --- | --- |
| fixed `DAY_COUNT = 365` | 30 / 43 |
| actual/actual | **43 / 43** |

43 consecutive monthly interest charges were compared. Every window falling
wholly within a leap year was overstated by the same relative amount, 2740 ppm,
which is exactly `366/365 - 1`; the two windows straddling a year boundary were
overstated by intermediate amounts and also resolved exactly under
actual/actual. That pattern is what excludes coincidence. Under actual/actual
the median residual is zero and the maximum is one cent, consistent with a
single rounding at the charge point.

**What this establishes:** a single hardcoded day-count basis cannot be assumed.
That finding is why the basis is now a per-loan property rather than a constant
(contract row C2, landed in #70) instead of the constant being quietly retuned
to fit one statement, which #11 explicitly forbids.

**What it does not establish:** that actual/actual is correct for any other
lender. This is one lender and one loan. It also verified **gross** interest
only — reconstructed as the charge plus the lender's own disclosed offset
saving, which is the lender's figure and not an independent check — so offset
accrual remains unproven.

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

## Outstanding after sign-off

G2 is signed (above), so none of these block the gate. The UI disclosure is the
one that should still land before daily accrual is user-visible.

- **Re-run the reconciliation against the per-loan basis.** The #65 run predates
  `loans.day_count_convention` (#70). It reconciled the engine against a fixed
  basis chosen by hand; it has not been re-run against the representation the
  code now actually uses. This is the last unchecked box on #65.
- **Disclose the basis in the UI.** #11 requires that where reconciliation shows
  a basis is only an approximation for a lender, "the UI copy must say so". No
  view, component or locale string currently mentions the day-count basis at
  all — it exists only in the model layer. C2 leans on this disclosure when it
  says selecting a basis is the borrower's assertion rather than a verified
  fact, so the contract currently promises something the interface does not
  deliver.
- **Offset movement.** Daily offset reconciliation needs the linked account's
  balance history, which the statements do not carry — they report the lender's
  own offset saving, not daily balances. Until that history is available, offset
  cases are out of scope for sign-off rather than tolerated within it. A
  sign-off that covers gross interest only must say so in those words.
- **Mid-cycle rate changes on the path users read.** The **persisted** schedule
  still does not use the daily path: `SCHEDULE_DAILY_ACCRUAL` is `false` on
  `main`, so production accrues monthly (#36) and a statement reconciliation
  exercises code users' numbers do not currently come from. Enabling it is #10,
  prepared and evidenced but deliberately unmerged pending this gate.
- **Independent finance review.** The sign-off above is the repository owner's,
  who is also the borrower whose statement was reconciled. That is a legitimate
  decision for a self-hosted project and it is what was given; it is not the
  same as an independent reviewer, and this document should not be read as
  claiming one.
- **Which basis a loan uses is now the borrower's assertion** (#65). The
  reconciliation that motivated it covers one lender and one loan: 43/43 charges
  resolve under actual/actual against 30/43 under a fixed 365, with every
  wholly-within-a-leap-year window wrong by exactly 366/365 − 1. That is
  evidence a single fixed constant cannot be assumed, not evidence that
  actual/actual is correct for any other lender. The default stays actual/365.
  The contract (C2) says the schedule discloses the basis in force rather than
  implying it is verified; that disclosure is **specified but not yet built** --
  see the UI bullet above -- so this row is not currently satisfied end to end.

No production release approval is granted by this document.
