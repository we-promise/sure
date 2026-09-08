# Loan amortisation release evidence

Status: G3 evidence below has been executed against production-shaped data, and
**gate G2a is signed** -- the non-offset scope. **G2b, offset reconciliation,
remains open**, and `docs/loans/methodology.md` carries the split, the owners and
the release-reporting rule. Daily accrual is therefore released rather than
prepared, on that qualified basis.

Any statement that "G2 is signed" without naming G2a overstates the evidence:
contract rows C15 and C16 are specified and unit-tested but **not
lender-reconciled**.

`Loan::AmortizationSchedule::SCHEDULE_DAILY_ACCRUAL` is `true` and
`ALGORITHM_VERSION` is `3`. The persisted schedule accrues daily and the figures
genuinely changed -- see the variance distribution below. The characterisation
suite was deliberately re-baselined, which the contract permits only after G2,
and the sign-off is what permitted it.

## What the G2 gate permitted

The contract says the characterisation suite "may be deliberately re-baselined
only after the lender reconciliation gate has been reviewed line by line". That
condition is met: the re-baseline was prepared on an unmerged branch while the
gate was open, and merged only once it was signed.

The order matters and is worth preserving as precedent. The figures below were
candidate figures under review until the signature, not approved figures --
which is why the branch was held rather than merged and backfilled.

## What re-baselining means here

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

### Two different numbers, on purpose

The CI gate and the deployment SLO are not the same measurement and must not be
conflated. Both are recorded here so nobody has to guess which one a given
figure is.

| | p95 | p99 | What it is |
| --- | --- | --- | --- |
| **Production-shaped SLO** | 100 ms | 150 ms | the deployment target, on hardware an SLO is written for. **Not enforced by CI.** |
| **CI regression gate** | 200 ms | 400 ms | a ceiling calibrated to the shared GitHub runner, enforced by the `Loan daily-accrual performance gate` step |

Calibration measurements, same workload, this runner:

| Run | p95 | p99 | Thresholds in force |
| --- | --- | --- | --- |
| 1 | 116.128 ms | 230.508 ms | calibration (effectively unbounded) |
| 2 | 112.643 ms | 221.674 ms | calibration (effectively unbounded) |
| 3 | 93.454 ms | 203.411 ms | **200 / 400 — passed** |
| 4 | 127.445 ms | 184.012 ms | **200 / 400 — passed** |

The runner does not meet the production SLO and is not expected to. Setting the
production number as the CI threshold would produce a permanently red build that
says nothing about the code, and the first fix anyone reaches for is raising the
threshold — which is how a gate stops meaning anything.

Note the spread, and note how it behaved as samples accumulated. For *identical
code* these four runs span roughly p95 93–127 ms and p99 184–231 ms — and every
run so far has widened that span rather than settling inside it, at one end or
the other. Run 3 set a new p95 low and run 4 immediately set a new p95 high
while setting a new p99 low.

Two things follow, and they are the reason this section exists:

- **The span is a property of the shared runner, not of the calculation.** The
  ceilings are sized against that noise rather than against any one measurement,
  which is why they sit well clear of the worst figure yet seen instead of
  snugly above the mean.
- **A single CI measurement is not evidence of a performance change**, in either
  direction. A figure near a ceiling is evidence about the runner until a second
  run agrees; a fast run is not evidence of an optimisation. Do not retune the
  thresholds from one build.

Add new measurements to the table above rather than restating the range in prose
or in the workflow comment — quoted ranges here have already gone stale twice.

### The 74.984 ms figure recorded elsewhere

An earlier local measurement of 74.984 ms appears in this repository's history
with no commit id and no environment recorded. **Do not quote it as evidence for
either threshold**, and note carefully what the measurements here do and do not
establish about it.

Two runs on this sandbox:

| What was measured | p95 |
| --- | --- |
| commit `afcb0de` | 214.886 ms |
| `main` at the time (`1fb3f4e`) | 200.960 ms |

- **What this does establish:** nothing measured here comes anywhere near
  74.984 ms, on either commit. Whatever conditions produced that figure are not
  reproducible from what is written down, so it is not a number this code can be
  held to.
- **What this does NOT establish:** that the gap is caused by hardware. These are
  two *different commits*, so code differences are not excluded — and the 74.984
  figure has no recorded commit to compare against in the first place. An earlier
  version of this section asserted "the variation is hardware, not code"; that
  claim outran its evidence and has been removed.

Isolating environment from code would need the *same* commit measured in both
places. That has not been run, and is not worth running: the CI thresholds above
are calibrated from repeated runs in the environment that enforces them, which is
the comparison that actually matters.

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
| Amortisation rows written | 5,232 |
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

Run rebuilds only as an explicit, bounded operation. **Pass `LIMIT` on every
slice**: omitting it makes `loans:rebuild_schedules` process every eligible loan
in one invocation, which is the opposite of the bounded rollout this section
requires.

    RAILS_ENV=production bin/rails loans:rebuild_schedules BATCH_SIZE=100 LIMIT=500 SLEEP=0.25

Check progress after each slice. This exits 0 only when every loan is at the
current algorithm version, so it is also the answer to "is the prebuild done?":

    RAILS_ENV=production bin/rails loans:schedule_version_status

`LIMIT` selects by id order, so repeating the command re-selects the same head of
the estate. That is safe rather than wasteful — the rebuild is idempotent, and
already-current schedules are cheap — but it means a slice is not a cursor:
raise `LIMIT` between slices (500, 2000, 10000, …) and watch the monitoring
signals below settle after each, rather than expecting successive equal-sized
slices to walk the estate.

Record queue depth, failures, stale schedules, convergence, and variance after
each slice. A rebuild is idempotent and rate-limited; page views do not own
completion.

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
executed evidence above, not guessed.

Each row names the command that measures it. A threshold with no way to read it
is not a monitoring signal -- the stale-schedule row was exactly that until
`loans:schedule_version_status` existed, and `algorithm_version`, the column
added to make it queryable, was written and validated but read by nothing.

`loans:schedule_version_status` exits non-zero while any loan is behind, so a
deploy step can block on it rather than an operator eyeballing a number:

| Signal | Threshold | How to measure | Rationale |
| --- | --- | --- | --- |
| Stale schedules | trending to 0; alert if not falling | `bin/rails loans:schedule_version_status` | the prebuild owns completion, not page views |
| Failed rebuilds | any failure investigated | job backend (rebuilds run as `LoanAmortizationRebuildJob`) | 32/32 succeeded in rehearsal |
| Convergence regressions | zero tolerance | `loans:amortization_variance` (`*_converged` columns) | 32/32 converged in both modes |
| Per-loan interest delta | alert above 1% | `loans:amortization_variance` (`interest_delta`) | observed range -0.77% to +0.57% |
| Rebuild queue depth | alert on sustained growth | Sidekiq queue depth | rebuild is throttled and idempotent |

## Outstanding approvals

- **G2a/#11: signed** (non-offset scope only; **G2b remains open**) by the repository owner, on the real statement
  reconciliation in #65. The evidence above shows this change is internally
  consistent, reversible and bounded; G2 is what speaks to whether daily accrual
  matches a real lender, and it does so for one lender, one loan, and gross
  interest only. `docs/loans/methodology.md` carries the carve-outs -- offset
  accrual in particular remains unproven against a statement.
- G1/#6: approved by the repository owner.
- G3: production-shaped rebuild and rollback observations -- **executed above**.
