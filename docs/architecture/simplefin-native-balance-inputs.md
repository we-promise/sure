# SimpleFIN sparse-history balance inputs

The native SimpleFIN path now retains and publishes its transaction observations
before evaluating balances. This preserves the legacy importer's useful ordering:
new raw history is available to the credit-card classifier while its preference
for an already sufficient ledger history uses the original pre-import baseline.
The implementation and seven focused regressions are written but unrun. SimpleFIN
remains disabled for native activation.

## Execution and evidence

`Simplefin#account_stream_dependencies` declares that balances require completed
transactions. The shared syncer orders those resources accordingly. Failed or
deferred prerequisites skip their dependents without adding another error; the
original failure or `DeferredPage` still determines the Sync outcome. Holdings
remain independent. A partially retained transaction page cannot authorize a
balance calculation.

Every transaction page retains its original per-account classification snapshot
as encrypted `balance_policy_baseline` evidence, alongside the unchanged provider
response. After the transaction checkpoint completes, `Simplefin::BalanceInput`
reads the first applied sequence-zero transaction batch belonging to this exact
connection, family, external account, namespace and logical Sync. It verifies both
that first batch and the current complete checkpoint against the current source
binding, including link and transaction source-policy revisions.

The earliest writer epoch supplies the baseline even when `provider_attempt`
increases. Later attempts may start after earlier pages have already posted new
entries. Selecting their factory snapshot would change the classifier's
entry-versus-raw-history decision. The original baseline remains intentional and
proof-bound; the completing checkpoint may belong to a later attempt of the same
Sync, but neither endpoint can silently adopt a different link or source policy.

For sparse CreditCard history, `Snapshot#refresh_raw_history` replaces only raw
history aggregates. Entry metrics, settings, sticky hint, observation time and
source identity stay at their original captured values. The aggregate reads
accepted transaction SourceRecords and their retained typed observations, merged
with retained migration history using the existing preference rules. The
liability date remains posted-first, even when a credit-card ledger entry uses
the transacted date. Canonical pending filtering still applies; the complete raw
response remains available in encrypted evidence and pending absence remains
non-authoritative.

The captured input includes the original baseline batch UUID and the terminal
transaction checkpoint UUID, revision and batch UUID. It is supplied through the
balance request's canonical account Record, so existing RequestInputs
fingerprinting rechecks it under source locks before publication. Existing
RequestGrant and RuntimeInputs checks continue to pin live credentials,
configuration and account routing. No network request is added inside these
database transactions. Balance evidence retains the exact classifier snapshot and
input references; replay uses that captured response rather than a new balance
observation or a newly computed entry baseline.

## Resource authority and acceptance

Another provider may remain selected for transactions while SimpleFIN supplies
balances. SimpleFIN's secondary transaction writer retains account-bound
SourceRecords but creates no Entry or EntrySource. Those observations can still
support its balance classifier. The transaction policy must remain the exact
revision admitted for both the retained baseline and the completing checkpoint.

`simplefin/balance_input_test.rb` covers fresh posted/transacted-date evidence,
pending exclusion/inclusion, split resource authority, failure before balances,
same-Sync continuation scheduling, new-attempt baseline invariance and captured
balance replay with source-policy change rejection. The scheduling assertion uses
the real SyncJob/Sync path with queue deferral disabled only for the test's outer
rollback transaction; it does not establish committed queue delivery. Existing
SimpleFIN history-window tests also cover interrupted multi-page replay.

Runtime execution, full provider parity, durable transfer of cache-only liability
sign hints, migration history verification, lifecycle/relink concurrency and
cutover remain acceptance requirements. This change neither migrates data nor
activates a provider.
