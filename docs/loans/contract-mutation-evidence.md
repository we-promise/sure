# Contract mutation evidence (gate G1)

G1 requires each C1–C16 row of `docs/loans/calculation-contract.md` to name a
test that demonstrates it. `loans:verify_contract_coverage` proves each row
names a test that **exists**. It cannot prove that test would **notice** if the
behaviour changed, and a test that passes without exercising its row satisfies
the coverage gate exactly as well as one that does.

`loans:verify_contract_mutations` supplies the missing half. For each row it
breaks the row's behaviour in production code and requires that row's own named
tests to go red:

```
bin/rails loans:verify_contract_mutations              # all 16 rows
ROWS="C8 C10" bin/rails loans:verify_contract_mutations # selected rows
```

Per row it (1) asserts the mutation's anchor matches its production file
exactly once, (2) runs the row's named tests unmutated and requires them to
pass, (3) applies the mutation and requires them to fail, (4) restores the file.
A row whose tests survive its mutation fails the task. The mutations live in
`config/loan_contract_mutations.yml`; `Loan::ContractMutationManifestTest` keeps
the anchors honest in the ordinary suite, so a refactor that moves one fails
next to the change rather than minutes later inside the gate.

## Transcript

Run on `feat/contract-mutation-evidence` at `35d2294` (Ruby 3.3.6, PostgreSQL 16):

```
C1   baseline=pass  mutated=failed    the accrual denominator stops being 365, so a full non-leap year no longer equals balance x rate
C2   baseline=pass  mutated=failed    leap years silently switch to a 366 denominator instead of 366 elapsed days over 365
C3   baseline=pass  mutated=failed    daily accrual stops receiving offset change points for the period
C4   baseline=pass  mutated=failed    the boundary guard stops rejecting a starting balance dated after accrual start
C5   baseline=pass  mutated=failed    the payment calendar is built one payment short of the loan term
C6   baseline=pass  mutated=failed    an extra repayment landing exactly on a payment date is dropped instead of applied before the payment
C7   baseline=pass  mutated=failed    a mid-period rate change no longer segments the accrual window, so the whole period runs at the old rate
C8   baseline=pass  mutated=failed    the accrual clock is seeded from the payment-sizing rate, re-rating the period that ENDS on the boundary (the #48 defect)
C9   baseline=pass  mutated=failed    same-day event order is reordered so payment precedes accrual
C10  baseline=pass  mutated=failed    the accrual window stops being half-open, so a rate effective ON the window's first day is ignored instead of applied from it
C11  baseline=pass  mutated=failed    every run holds the first payment, so re-amortisation stops re-sizing per rate segment
C12  baseline=pass  mutated=failed    each segment is rounded as it accumulates instead of once at the charge point
C13  baseline=pass  mutated=failed    change points stop splitting the range, so piecewise accrual no longer equals the daily loop
C14  baseline=pass  mutated=failed    the last scheduled payment no longer settles the remaining balance
C15  baseline=pass  mutated=failed    the offset floor is removed, so an offset above the balance produces negative interest
C16  baseline=pass  mutated=failed    a change point effective on the first day of the range is ignored rather than applied to the whole range
Verified 16 contract rows: every row's tests pass unmutated and fail when its behaviour is broken
```

## What the first run found

The first full run was **not** 16 green. Five rows survived their mutation, and
recording why matters more than the clean transcript above — two of them were
gaps in the row's evidence, not merely weak mutations.

| Row | First result | Diagnosis | Resolution |
| --- | --- | --- | --- |
| C8 | survived | Weak mutation. Re-seeding the accrual clock from `accrual_rate_for(payment_date)` returns the same rate as the correct seed for the test's fixture, so nothing moved. | Mutation now seeds from `segment[:rate]` — the payment-sizing clock, which is the actual #48 defect. |
| C10 | survived | Weak mutation. Dropping the accrual clock's carry-forward is invisible when the same change is re-seen as an in-window change point in the following period. | Mutation now closes the half-open window (`>=` → `>`), so a rate effective on the window's first day is ignored. |
| C11 | survived | Weak mutation. `held_payment ||=` differs from `=` only across rate segments, and the hold fixture has one segment. | Mutation now forces every run onto the hold branch, which the re-amortisation test catches. |
| C12 | **survived — evidence gap** | The named test charges a **single** segment. Rounding 10.19178… to cents once and twice gives the same answer, so the test could not distinguish single from repeated rounding at all. | Added `charge accumulates segments unrounded and rounds once at the end`: three segments whose per-segment rounding lands a cent below the single rounding. Row now names both tests. |
| C16 | **survived — evidence gap** | The named test passes offsets in the legacy `offset_changes:` shape, filtered by `normalize_changes`. Production (`Loan::Simulator`) always passes `change_points:`, filtered by a different method — so the row's evidence covered a call shape production does not make. | Added `a change point at the range start applies to the full range` against the production shape. Row now names both tests. |

The C12 and C16 findings are the reason this task exists: both rows passed
`verify_contract_coverage`, and both named tests that were green — and neither
row's evidence actually covered the behaviour the contract claims.

## What this does and does not establish

**Establishes.** For every row C1–C16 there is at least one concrete defect in
production code that the row's named tests detect. A row can no longer name a
test that never exercises it.

**Does not establish.**

- **Not correctness.** Mutation evidence shows the tests are sensitive to a
  defect, not that the specified behaviour is the right behaviour for a lender.
  That is G2's job, and #65 shows one lender where a contract default was an
  approximation.
- **Not exhaustive, and not whole-row.** One mutation per row: the transcript
  shows each row's tests are sensitive to *that* defect, not that they cover
  everything the row specifies. Where a row spans two behaviours the mutation
  takes one of them — **C16** is the standing example. Its mutation exercises
  the interest-bearing-balance half in `Loan::InterestAccrual`; the forward-flat
  half is implemented and tested (`Loan::OffsetResolverTest`, "holds today's
  offset total flat for future ranges", landed with #13) but is not verified
  from C16, because `config/loan_contract_tests.yml` binds one test class per
  row. Letting a row name tests in more than one class is the follow-up that
  would close it. Surviving mutants outside this set certainly exist.
- **Not approval.** G1 also requires engineering and product sign-off on the
  contract document. That remains outstanding on #6 and nothing here grants it.
