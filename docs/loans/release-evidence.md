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

## Variance and rebuild

Run the non-mutating sample report before release:

    RAILS_ENV=test LIMIT=100 OUTPUT=tmp/loan-variance.csv bin/rails loans:amortization_variance

Run rebuilds only as an explicit, bounded operation:

    RAILS_ENV=production bin/rails loans:rebuild_schedules BATCH_SIZE=100 SLEEP=0.25

Record queue depth, failures, stale schedules, convergence, and variance. A
rebuild is idempotent and rate-limited; page views do not own completion.

## Rollback rehearsal

Before deployment, run the previous-version rebuild path against a disposable
database, verify row counts and schedule signatures, apply the new version,
then roll back and verify the previous rows can be regenerated. Record only
aggregate results and identifiers that are safe for repository publication.

## Outstanding approvals

- G2/#11: real approved lender statement and finance reviewer sign-off.
- G1/#6: contract and test traceability approval.
- G3: production-shaped rebuild and rollback observations.
