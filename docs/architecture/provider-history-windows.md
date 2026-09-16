# Provider transaction history windows

The ordinary account-scoped syncer now asks an adapter for its initial history
start instead of imposing the shared 90-day default on every provider. The old
shared window clipped Akahu and Wise adapter defaults and omitted SimpleFIN's
legacy lookback policy. These declarations now drive production sync requests.

| Provider | Initial transaction history with no configured start/checkpoint | Completed checkpoint |
| --- | --- | --- |
| Akahu | No start date; request the history accessible through Akahu | Seven days before `covered_through` |
| Wise, `import_all_history: false` | 365 days before the captured Sync creation instant | Seven days before `covered_through` |
| Wise, `import_all_history: true` | Account `creation_time`; January 1, 2000 UTC when absent | Seven days before `covered_through` |
| SimpleFIN | 360 days before the captured Sync creation instant; initial ranges cannot start before one calendar year ago at UTC midnight | Thirty days before `covered_through` |
| Other ordinary adapters | Existing 90-day default | Existing seven-day overlap |

An account's configured start takes precedence over the connection's start; both
take precedence over a checkpoint or provider default. An earlier per-Sync start
widens the selected range. A later per-Sync start does not narrow an existing
dated range. For an unbounded Akahu initial request, an explicit per-Sync start
supplies the requested bound. A per-Sync end can stop the range earlier; it cannot
extend beyond the Sync creation instant. A delayed worker therefore uses the
same captured clock. SimpleFIN additionally clamps initial ranges, including
explicit starts, to its one-calendar-year floor. That floor never narrows an
incremental gap or explicit repeat backfill after a completed checkpoint. An end
before the allowed initial start is rejected without a transaction checkpoint.
Provider-specific continuation and grouped transaction
generation protocols retain their existing behavior.

The adapter history hooks are pure policies. `initial_history_start` selects the
initial default, `checkpoint_history_start` supplies the overlap from a completed
checkpoint, and `initial_history_floor` optionally limits initial backfills.
They receive an immutable account metadata projection and the captured clock;
the checkpoint hook also receives the exact `covered_through` timestamp. They
return a date/time or an allowed `nil`, and perform no reads, writes, or HTTP. Adapters
declare the metadata they need through `initial_history_metadata_keys`; Wise
declares only `creation_time`. The existing `RequestInputs` proof fingerprints
these selected metadata values alongside configured start/end dates, then
rechecks them at request admission and publication. The exact admitted account
Record, window and cursor remain covered by the existing request proof. Factory
configuration proof separately pins Wise's `import_all_history` setting. A
changed input rejects the attempt; the runtime does not silently rebuild the
adapter or select a different history range. Evidence contains keyed
fingerprints rather than configuration values.

Wise retains its 30-day statement pages, followed by the activities phase; its
date window also filters applicable activity/transfer records. Akahu retains
posted pagination followed by the pending inventory. A checkpoint only advances
after the relevant existing page protocol completes. These changes do not turn
legacy timestamps into accepted native checkpoints or prove that previously
captured history has been imported.

[Akahu cutover history](akahu-cutover-history.md) now verifies the retained cache
against original financial evidence before handing over. It preserves each
explicit account/item floor and uses an explicit nil result for full accessible
history otherwise. The cutover receipt retains every account key, and the adapter
declares `akahu_initial_history_start` for request-input pinning. An old completed
item Sync does not narrow that first read or become a native checkpoint. Akahu
activation and executable acceptance remain gated.

SimpleFIN's legacy `SimplefinItem::Importer#import_with_chunked_history` requests
60-day chunks, chooses a 360-day target by default, caps custom targets at one
calendar year, limits the run to six requests, and stops after two consecutive
chunks add no linked raw-cache transactions. `determine_sync_start_date` uses a
30-day buffer after a completed legacy sync. Its separate 60-day first-run helper
belongs to the regular fallback path, rather than the full initial history path.
These lookback and stop settings are constants in the legacy implementation;
there is no additional configuration to resolve or copy into the native factory.

The native SimpleFIN adapter preserves the initial target/cap and repeat overlap,
and continues every 60-day page needed to cover the selected range. It does not
use raw-cache growth or an empty page to infer that older dates contain no data.
The ordinary 360-day target therefore takes six requests even when recent pages
are empty. An explicit initial range reaching the calendar-year floor can require
a seventh short page; an overdue repeat sync can require more. This is a deliberate
completeness change from the legacy early stop/request limit. Discovery remains
unwindowed, and transaction checkpoints advance only after all requested pages
complete; missing pending observations still cannot authorize deletion.

The focused production-Syncer suites are
`test/models/provider/account_data/history_windows_test.rb` and
`test/models/provider/account_data/simplefin_history_windows_test.rb`. They cover initial
defaults, explicit date precedence, captured time, checkpoint overlap, multiple
pages in one invocation, Wise's missing-date fallback, and rejection after
creation-date/history-setting changes, SimpleFIN's calendar-year/leap-year cap,
old incremental gaps, retained older transactions after empty recent pages, and
interruption/retry without premature checkpoint advancement. These tests have not been executed in
the current environment because Ruby is unavailable. Native readiness and
cutover flags remain unchanged.

Checkpoint transfer/acceptance, Wise's per-account transfer/statement policy and
connection-wide fallback decisions, and coordinated cutover verification remain
separate migration requirements. This window fix does not establish those
acceptance conditions.
