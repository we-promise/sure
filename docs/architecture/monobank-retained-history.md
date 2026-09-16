# Monobank retained history input

The native Monobank factory now receives an explicit, frozen
`monobank_retained_history` collector input. It no longer selects the first
checkpoint that happens to contain a `columns` document. The implementation and
eight new behavioral tests are written but unrun; native activation remains false.

## Legacy behavior preserved

The legacy importer selects its forward statement start from the oldest of the
last `statement_synced_through`, the configured pending lookback, and the oldest
stored hold. It then clamps that start to Monobank's maximum statement window.
`history_synced_from` separately records the lower boundary for backward history.
Per-account and connection start dates determine the requested history target.

`Monobank::RetainedHistory` reads the accepted account archive through shared
`RetainedRow`. It verifies the original copied account binding and derives
`oldest_pending_at` from `raw_transactions_payload`, using the legacy Boolean
casting, omitted-time handling and epoch `to_i` behavior. Settled transactions do
not extend pending overlap. The existing adapter still decides pending inclusion,
clamps statement windows, spends its physical request budget and handles rate
limits. The collector never calls a legacy importer, processor or provider client.

Only the exact `legacy_state` checkpoint for
`MonobankAccount:<original-source-UUID>` is accepted. Its family, connection,
ExternalAccount, schema and format must match the retained descriptor. Its two
decoded columns must equal the archived `statement_synced_through` and
`history_synced_from` values. Missing, ambiguous or unrelated checkpoint state is
rejected. A copied state with a native cursor, progress, batch, generation or
`covered_through` is rejected. `last_synced_at` is never promoted into statement
coverage.

## Request and replay contract

The collector is registered explicitly in RuntimeContext and RuntimeInputs. Its
`build(connection:, observed_at:, external_accounts:)` method reads archives once
under factory admission. Its separate `live_input(connection:)` reads bounded
source descriptors, copied checkpoint state and current account/link context;
these values join RequestGrant's live configuration fingerprint before HTTP and
again before publication. Per-request validation does not decrypt transaction
archives.

Each captured account is keyed by ExternalAccount UUID and carries its provider
ID, namespace, copied source/control/mapping/checksum/copy-run provenance, link
revision, financial account identity and current flags. The factory verifies
these against its admitted account inventory. Every account request uses that
UUID and namespace to select its seed. A genuinely new, unmapped source receives
an explicit empty retained seed; a mapped source with missing evidence fails.

Ordinary native transaction checkpoints are excluded from the retained input's
live fingerprint. Their progress cursor and completed cursor continue to take
precedence in the adapter's existing state machine. Advancing native progress
does not reread an archive, replace the initial seed or invalidate the retained
source proof. Changing copied boundaries, link context or source provenance does
invalidate the proof. The collector makes no checkpoint, account, ledger or
activation writes.

Factory capture is limited to 1,000 external accounts, 32 MiB of cumulative
decoded account archives and 100,000 transaction rows per archive. Copied
checkpoint documents have a 64 KiB decoded bound and a stored-size preflight.
Larger histories require an explicit bounded installation protocol before they
can be accepted; they are not silently truncated.

Tests use real quiesced copies, Registry/RequestGrant construction and archived
checkpoint values. They cover hold selection, pending exclusion, request budget,
native progress/replay, changed copied state, missing archives/mappings, ambiguous
and unrelated state, relinking, foreign inventory and namespace rejection. They
leave copied connections disabled. Full runtime parity, pending expiry behavior,
legacy lifecycle fencing, auxiliary-data verification and cutover remain separate
acceptance requirements.
