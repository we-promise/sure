# Bills and Recurring Transactions

This document explains how Sure detects recurring bills, when the detection
pipeline runs, and the maintenance tasks available to self-hosters.

## How detection works

Sure clusters your transaction history into recurring patterns (same
merchant or name, consistent amount within tolerance, consistent day). A
pattern needs at least three consistent occurrences to become a series.
New detections land with status `suggested` and wait in a review strip on
the Bills page (and under Settings -> Recurring transactions) until you
confirm or dismiss them. Dismissing leaves a tombstone, so a dismissed
pattern is never suggested again.

## When the pipeline runs

The full pipeline (detect patterns, materialize upcoming occurrences,
repair provider-replaced entries, match payments, detect price changes)
runs automatically:

- after every completed bank sync or import (debounced by 30 seconds)
- nightly at 05:30 UTC (occurrence materialization only, for families
  that never sync)

And on demand:

- the **Find recurring transactions** button on an empty Bills page
- the **Identify Patterns** button under Settings -> Recurring transactions

All triggers share one per-family lock, so concurrent runs never stack.

## First run on existing data

The user-triggered detection actions (the **Find recurring transactions**
button on an empty Bills page and the **Identify Patterns** button under
Settings -> Recurring transactions) backfill the last six months of
history: past occurrences are generated and closed as paid where a real
transaction anchors them. Past occurrences no transaction covers are
deleted rather than shown as missed, so the backfill reconstructs what
happened without fabricating debt. The backfill is idempotent, so
re-running detection never duplicates history. Background syncs never
backfill; on an instance upgraded from a build without the Bills
subsystem, run either detection action once to reconstruct history.

Confirming an individual suggestion likewise backfills that bill's own
history, so a just-confirmed bill shows its lived past instead of
starting blank.

## Maintenance tasks

Both tasks are safe to re-run; they only close history a real entry
anchors and never touch existing payment records.

```bash
# Rebuild N months of occurrence history for every family (default 6)
bin/rails "recurring:backfill_history[12]"

# One-shot classification of auto-detected series still on defaults
# (assigns bill/subscription/installment kind and a category)
bin/rails recurring:classify_existing
```

## Disabling the feature

Settings -> Recurring transactions has a per-family toggle. Disabling
hides the Bills page and stops all detection and materialization for
that family.
