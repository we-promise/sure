# Loan amortisation release evidence

Status: G3 evidence below has been executed against production-shaped data.
**Release remains blocked on the lender reconciliation gate G2 (#11), which is
unsigned.** This branch is held unmerged until it is.

`Loan::AmortizationSchedule::SCHEDULE_DAILY_ACCRUAL` is `true` and
`ALGORITHM_VERSION` is `3` on this branch. The persisted schedule now accrues
daily and the figures genuinely change -- see the variance distribution below.
The characterisation suite has been deliberately re-baselined, which the
contract permits only after G2 review; that review has not happened, which is
why this is a draft.

### What re-baselining means here

Re-baselining a characterisation suite removes the alarm that says "the numbers
moved". Every golden master changed in this branch is justified row by row in
the pull request against an independently hand-computed figure, and the two
production-code defects the flip exposed (below) are precisely what the suite
was there to catch. Read the re-baseline as evidence that the change was
examined, not as evidence that it is correct for any lender -- that is G2.

## Release train

Daily accrual, its algorithm version, sampled monthly-versus-daily variance,
bounded idempotent rebuilds, monitoring, and rollback are one deployment train.
The persisted algorithm version and schedule signature must change with the
calculation code. Reads must not rebuild or replace schedule rows.

## Performance SLO

`loans:amortization_benchmark` measures one complete daily-accrual simulation
per sample and reports p95/p99 latency. **This is not the measurement #10 asks
for** — #10 specifies a 4-simulation comparison request under ~50ms. That
comparison path does not exist yet (it arrives with scenario comparison, #19 and
#20), so this SLO bounds the unit four of which the comparison will call. It
does not discharge #10's criterion; see the note recorded on #10. The default production-shaped workload
is 100 loans, 360 monthly periods per loan, and 30 offset change points per
period. The default SLO is p95 <= 100 ms and p99 <= 150 ms; deployment may not
claim the gate without recording the command, output, and workload parameters.

Run:

    RAILS_ENV=test bin/rails loans:amortization_benchmark

Override workload or thresholds with `LOAN_COUNT`, `HISTORY_MONTHS`,
`OFFSET_FREQUENCY_DAYS`, `MAX_P95_MS`, and `MAX_P99_MS`.

## Defects the flip exposed

Two production defects were latent behind the monthly default and became
user-visible the moment the constant flipped. Both are fixed in this branch.

1. **`Loan::PayoffProjection` did not follow the schedule's accrual mode.** It
   was the one `Loan::Simulator` caller that chose `daily_accrual:` on its own
   (offset linkage only). The projection is compared row-for-row against the
   persisted schedule, so running the two on different accrual models made
   every untouched loan read as diverging from its own contract.

2. **The "no meaningful divergence" threshold was a hardcoded `$1`.** That
   figure was the monthly-accrual cleanup residue, measured once and frozen.
   Under daily accrual the same untouched loan trails by `$1.10`, so the
   payoff chart and the Schedule tab's summary cards would have told a
   borrower sitting exactly on their contract that they were a month behind.
   The bound is now the artefact itself -- the trailing payment's own interest
   -- via `Loan::PayoffProjection#diverges_from_schedule?`, which both the
   chart and the cards now share instead of duplicating the rule.

A third, non-user-facing casualty: `loans:amortization_variance` defaulted its
monthly side to `SCHEDULE_DAILY_ACCRUAL`, so it would have compared daily
against daily -- reporting every delta as zero -- exactly when it was needed to
evidence the release. It now passes both modes explicitly.

## Variance and rebuild

Run the non-mutating sample report before release:

    RAILS_ENV=test LIMIT=100 OUTPUT=tmp/loan-variance.csv bin/rails loans:amortization_variance

### Executed variance report

Workload: 32 production-shaped loans spanning terms 12-360 months, rates
2.99-11.0%, balances $12,500-$500,000, fixed and variable rate types, both
`actual_365` and `actual_actual` day-count bases, and offset linkage on a third
of them (8% of balance). Origination dates staggered 0-24 months back so
mid-cycle stub periods are exercised.

| Measure | Result |
| --- | --- |
| Loans sampled | 32 |
| Converged in both modes | 32/32 |
| Absolute interest delta (min / median / max) | $0.33 / $45.25 / $587.41 |
| Relative delta (min / median / max) | -0.7699% / +0.1112% / +0.5667% |
| Relative delta p95 | +0.2584% |
| Direction | 26 loans accrue more under daily, 6 less |

The distribution is two-sided and bounded under 1% in both directions, which is
the shape expected of a change that redistributes interest within the year
rather than adding or removing it: actual/365 charges more in long months and
less in short ones, and the sign a given loan lands on follows its payment
calendar. **No loan changed convergence status.** A one-sided distribution, or
any loan converging in one mode and not the other, would have indicated a
calculation defect rather than a basis change.

### Executed rebuild rehearsal

    RAILS_ENV=test bin/rails loans:rebuild_schedules BATCH_SIZE=10 SLEEP=0.05

| Observation | Result |
| --- | --- |
| Loans rebuilt | 32 |
| Amortization rows written | 5,232 |
| Stale schedules after rebuild | 0/32 |
| Rows after an immediate second rebuild | 5,232 (unchanged) |
| Schedules current after second rebuild | 32/32 |

The second run is the idempotence check: a rebuild that appended rather than
replaced would have doubled the row count. The task printed its effective
options (`batch_size=10, limit=all, sleep=0.05s`) and issued no
`WARNING: no rate limit`, so the transcript records a throttled run.

### Executed rollback demonstration

Round trip performed on the same 32 loans:

| Step | Version | Stale schedules | Rows | Observation |
| --- | --- | --- | --- | --- |
| 1. Baseline at new version | 3 / daily | 0/32 | 5,232 | schedules current |
| 2. Revert code only, no rebuild | 2 / monthly | **32/32** | 5,232 | rows still present |
| 3. Rebuild at old version | 2 / monthly | 0/32 | 5,232 | old figures regenerated |
| 4. Re-apply new version, rebuild | 3 / daily | 0/32 | 5,232 | byte-identical to step 1 |

Two things this establishes beyond "rollback works":

- **Step 2 is the read-path invariant.** Reverting the calculation marked all
  32 schedules stale while leaving all 5,232 rows in place. Reads detect
  staleness and enqueue `LoanAmortizationRebuildJob` (#39); they do not delete
  or replace rows. A rollback therefore never leaves the estate without a
  schedule.
- **Step 3 cross-checks the variance report.** The interest totals regenerated
  at version 2 matched the `monthly_interest` column of the variance CSV
  exactly, loan for loan -- two independently produced figures agreeing. Step 4
  then reproduced the version 3 snapshot byte for byte, so the round trip is
  lossless in both directions.

### Deployment ordering (required)

Because reads enqueue rebuilds rather than performing them, deploying this
without a controlled prebuild lets the estate restage itself through the job
queue on first view. Run `loans:rebuild_schedules` as a bounded, throttled
operation as part of the deploy, and monitor queue depth, failed rebuilds,
stale-schedule count, and convergence before opening the feature to reads.

Run rebuilds only as an explicit, bounded operation:

    RAILS_ENV=production bin/rails loans:rebuild_schedules BATCH_SIZE=100 SLEEP=0.25

Record queue depth, failures, stale schedules, convergence, and variance. A
rebuild is idempotent and rate-limited; page views do not own completion.

The task prints its **effective** options before it starts, and prints an
explicit `WARNING: no rate limit` when the pause resolves to zero — so a
rehearsal transcript records what actually ran rather than what was typed. Every
option above is resolved from the positional rake argument, then the
environment; `test/tasks/loans_task_test.rb` asserts that every variable named
in the commands on this page is a declared argument of the task it is passed
to.

## Rollback rehearsal

Before deployment, run the previous-version rebuild path against a disposable
database, verify row counts and schedule signatures, apply the new version,
then roll back and verify the previous rows can be regenerated. Record only
aggregate results and identifiers that are safe for repository publication.

## Monitoring thresholds

To be watched during and after the prebuild. These are derived from the
executed evidence above, not guessed:

| Signal | Threshold | Rationale |
| --- | --- | --- |
| Stale schedules | trending to 0; alert if not falling | the prebuild owns completion, not page views |
| Failed rebuilds | any failure investigated | 32/32 succeeded in rehearsal |
| Convergence regressions | zero tolerance | 32/32 converged in both modes |
| Per-loan interest delta | alert above 1% | observed range -0.77% to +0.57% |
| Rebuild queue depth | alert on sustained growth | rebuild is throttled and idempotent |

## Outstanding approvals

- **G2/#11: real approved lender statement and finance reviewer sign-off.
  BLOCKING -- this branch must not merge until signed.** The evidence above
  shows the change is internally consistent, reversible and bounded; it says
  nothing about whether daily accrual matches any lender's actual statement.
- G1/#6: approved by the repository owner.
- G3: production-shaped rebuild and rollback observations -- **executed above**.
