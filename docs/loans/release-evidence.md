# Loan amortisation release evidence

Status: release evidence is pending execution against production-shaped data
and approval of the lender reconciliation gate in #11.

## Release train

Daily accrual, its algorithm version, sampled monthly-versus-daily variance,
bounded idempotent rebuilds, monitoring, and rollback are one deployment train.
The persisted algorithm version and schedule signature must change with the
calculation code. Reads must not rebuild or replace schedule rows.

## Performance SLO

`loans:amortization_benchmark` measures one complete daily-accrual simulation
per sample and reports p95/p99 latency. The default production-shaped workload
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
