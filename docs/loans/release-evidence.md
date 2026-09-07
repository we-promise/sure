# Loan amortisation release evidence

Status: release evidence is pending execution against production-shaped data
and approval of the lender reconciliation gate in #11.

**There is currently no calculation change to release.**
`Loan::AmortizationSchedule::SCHEDULE_DAILY_ACCRUAL` is `false` and
`ALGORITHM_VERSION` is `2`, so the persisted schedule accrues monthly and is
byte-identical to what is deployed. The tooling below is real and exercised, but
until daily accrual is enabled (#36) the variance report compares a shipped path
against an unshipped one, and G3 has nothing to rehearse.

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

## Variance and rebuild

Run the non-mutating sample report before release:

    RAILS_ENV=test LIMIT=100 OUTPUT=tmp/loan-variance.csv bin/rails loans:amortization_variance

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

## Outstanding approvals

- G2/#11: real approved lender statement and finance reviewer sign-off.
- G1/#6: contract and test traceability approval.
- G3: production-shaped rebuild and rollback observations.
