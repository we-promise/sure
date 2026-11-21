# Linked-account balance anchoring

`BALANCE_REUSE_EXPLAINED_ANCHOR` controls how Sure handles a linked account's stale, provider-reported balance anchor.

## Default: off

When the flag is unset or false, every stale anchor is kept as a reconciliation waypoint ("Manual balance update"). This preserves the pre-existing behavior.

## Enabled: explained anchors move forward

When the flag is truthy (`1`, `true`, or `yes`), the manager compares the stale anchor with the provider's new reading using the transactions imported in the same sync. If the imported ledger explains the move, the anchor is updated in place (amount and date). If it does not, the old anchor is preserved as a reconciliation waypoint and a new anchor is created.

Only `:cash` accounts are evaluated. Investment, crypto, and other non-cash accounts keep the old behavior. Providers that update account balances directly, such as SimpleFIN and Lunchflow, are outside this path.

## Rollout

- The flag is off by default. Enable it deliberately per installation.
- On the first reverse sync after enabling, materialized balance rows are recalculated and historical charts may move to corrected values.
- Existing reconciliation rows created by prior rotations are not deleted or rewritten. Provenance is not stored, so an automatic repair cannot distinguish a sync-created waypoint from a genuine user reconciliation.

## Rollback

Turning the flag off restores the old preserve-every-stale-anchor behavior for future syncs. It does not restore an anchor that was overwritten while the flag was enabled. Reverting the code has the same limitation.

If you need to preserve the pre-enable state, take a database backup and a baseline of daily balances before enabling the flag.

## Release note

> Linked-account balance anchoring is available behind `BALANCE_REUSE_EXPLAINED_ANCHOR` (default off). When enabled, provider observations explained by imported transactions are moved forward instead of being kept as daily "Manual balance update" reconciliations. Existing reconciliations are retained; there is no automatic historical repair. Enabling the flag can revise historical chart values and overwrites explained anchors irreversibly, so take a backup before enabling it.
