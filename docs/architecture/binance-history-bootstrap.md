# Binance retained history handoff

[`Binance::HistoryBootstrapPlan`](../../app/models/provider/account_data/binance/history_bootstrap_plan.rb)
is a read-only migration prerequisite. It offers a candidate history seed only
when every cached trade and both financial legs of every cached P2P order have
an unambiguous existing Entry in the retained linked financial account. It does
not post missing trades, publish financial identities, install cursors, or enable
the native provider.

The legacy [`BinanceAccount::Processor`](../../app/models/binance_account/processor.rb)
derives spot/futures `from_id` values from the largest cached trade ID, separately
for each market and pair. It starts P2P reads at the largest cached `createTime`,
including that millisecond. Despite processing before merging caches, a missing
security or quote conversion can silently skip a financial row. Legacy P2P also
skips an entire order if either its trade or funding Entry already exists. Thus a
cached maximum can be ahead of an unposted record, and a cached P2P order can have
only one financial leg. Copying those maxima directly would perpetuate the gap.

The planner uses the copier's retained quiesced verification, including original
copy-run checks, exact source/target projections, credentials, inventory and
archived copy-time financial linkage. Older archives without that binding must
be reconciled by the copier workflow; the planner cannot invent an original link.
It obtains a one-account verification page and, for a nonfirst
mapping, one additional page using an internal predecessor-ID cursor. It never
scans every account archive to find the selected account. It then reconstructs
the exact mapped account archive with its original source checksum. No `latest`
archive lookup or live provider request is involved.

```ruby
result = Provider::AccountData::Binance::HistoryBootstrapPlan.new(
  mapping: mapping,
  family: authorized_family
).call

result.ready?          # All cached identities have exact existing ledger rows.
result.cached_history  # nil whenever any cached row is blocked or unresolved.
result.document        # Immutable context, rows, blockers and acceptance flags.
```

Call outside a database transaction. The exact item's exclusive legacy permit
precedes a read-only repeatable-read transaction; provider HTTP and security/FX
resolution are absent. Retained verification uses its existing row locks inside
that transaction. This gives a coherent report while holding the declared legacy
writer permit. Consumers still need a final quiesced comparison before installing
any input; the returned document is not a durable authorization to advance a
checkpoint. `call(expected_context: previous.document.fetch("context"))` rejects
a different copy run, checksum, mapping, account/link revision, currency/type or
connection context.

Each accepted cache row retains its exact market/pair or P2P order/side, canonical
trade ID, timestamp, raw typed-value checksum and every archive path. Matching
uses exact source `binance`, exact `external_id`, expected `Trade`/`Transaction`
type, existing entryable and unique entryable ownership. It never reconstructs
identity from an amount or date, and user edits to financial values remain intact.
Identical cached duplicates preserve all paths; conflicting duplicates block the
whole seed. A missing P2P leg remains visible separately and prevents advancing
the timestamp even when the other leg exists.

The planner rejects noncanonical trade ID spellings that native integer parsing
would rewrite, unsupported pair topology, malformed numeric/side fields, raw
symbol/pair disagreement, timestamps later than the copy observation, and P2P IDs
colliding with the funding suffix convention.
Stablecoin base pairs are blocked because the current native task builder excludes
them. Blockers retain archive references for explicit reconciliation; they do not
silently repair, drop, or recompute those inputs.

Read bounds are 32 MiB decoded bytes and 1,024 encrypted archive chunks per source
archive, 10,000 cached occurrences per plan, and 16 MiB of typed result data. The
copier also preflights its source rows and archive reads. Ledger identity queries
run in batches of 250 and read only identity columns, avoiding large financial
JSON payloads. Oversized inputs fail closed; a durable paged accumulator for larger
histories is not implemented. Error messages and `inspect` omit raw values and
credentials. Retained archive paths and identifiers in the result are private
provider data and belong in encrypted state if a later workflow persists them.

[`Binance::HistoryBootstrap`](../../app/models/provider/account_data/binance/history_bootstrap.rb)
installs that candidate only after the financial identity publisher has completed
its verification sweep:

```ruby
installation = Provider::AccountData::Binance::HistoryBootstrap.new(
  mapping: mapping,
  family: authorized_family
).install(expected_context: result.document.fetch("context"))
```

The optional context rejects a stale reviewed report; the publisher always builds
a fresh plan itself. It runs inside the planner's explicit retained-plan callback,
under the same exclusive legacy permit and repeatable-read transaction. It checks
the verified identity checkpoint again through `IdentityBootstrap.run`, including
its final inventory, and verifies each cached trade and each P2P leg against its
active permanent posting proof. It locks Entry and entryable identity projections
in UUID order before checking live source IDs, type, entryable UUID and pending
aliases. Ordinary monetary, security, description and protection edits remain
unchanged. Missing or withdrawn proof is a conflict, never permission to recreate
an Entry or skip a cached record.

Installation atomically adds one encrypted immutable migration `IngestionBatch`
and one encrypted `ProviderSyncCheckpoint` in `legacy_binance_history`, scoped to
the exact ExternalAccount UUID. The signed receipt binds both installation UUIDs,
the original copy/account context, complete plan, permanent proof references and
the verified financial-identity checkpoint. It uses the explicitly configured
retained identity signing keyring; those verification keys must remain available
for the receipt's lifetime, including after encryption or application-secret
rotation. The checkpoint has no cursor or coverage date. No provider Sync or
upstream-completeness claim is created. An identical retry returns the same IDs;
changed context/proofs, an orphaned receipt or any native execution/progress
rejects installation. Copy restart and return to legacy still reject retained
receipts, including when their checkpoint was lost. Retained read-only copy and
identity re-verification can continue without replacing evidence.

`HistoryBootstrap#verify!(checkpoint_id:, batch_id:, receipt_digest:)` verifies an
existing installation after a new identity sweep. It repeats the retained plan,
checks current financial identity tuples and original permanent posting proofs,
and requires the original seed checkpoint, batch and digest. The identity
checkpoint must again be fully verified. Its verification timestamp and advancing
optimistic-lock revision may differ from the signed installation snapshot; its
UUID, capture inventory, source bindings and completed counts remain fixed. A
regressed revision is rejected. This command never creates a missing
seed or changes its signed payload. Re-running `install` is not a substitute for
this verification command after restarting the identity sweep.

The version-two [preparation coordinator](provider-migration-preparation.md) now
installs this input after initial financial identity publication, then verifies
it after fresh copy and identity sweeps. Per-account preparation receipts retain
the original checkpoint/batch UUIDs and digest across child-commit interruptions
and later verification runs. Unlinked accounts and unsupported non-single-combined
topologies receive explicit unresolved dispositions; neither creates a seed or
counts as an installed input. Other providers' unfinished handoffs remain visible
through the coordinator's input-integration status.

The native factory explicitly declares the `binance_history_seed` RuntimeContext
input. Its reader verifies the signed receipt and exact original account/link
revision, namespace and financial account identity without invoking the legacy
planner. Native ownership and credential/lease epochs can advance; an account
relink, currency/type change or source-identity change requires reconciliation.
The complete installed checkpoint descriptor and seed participate in the keyed
live input fingerprint before HTTP and at publication. Deleting, replacing or
changing installation state cannot silently establish a new factory baseline
inside an existing request. Ordinary `activities` progress is excluded from this
fingerprint and remains the sole continuation authority after it exists.

`ids` has independent spot/futures pair maps and `p2p_after` retains the inclusive
millisecond. Sold-out assets remain discoverable through retained pair keys.
Initial requests use the installed seed; subsequent durable activity cursors take
precedence without merging newly read cache maxima. The legacy date behavior is
unchanged: retained pair IDs/P2P maxima take precedence over configured dates;
dates govern history without a retained maximum. This is not a backfill command.
The native path never rereads the legacy cache to reconstruct starting input.

The installation receipt is limited to 24 MiB, its checkpoint/identity-checkpoint
state to 1 MiB each, and selected live pending identity data to 12 MiB. The native
input check currently verifies the full bounded receipt on each admission and
publication. This favors correctness over a compact attestation cache; read cost
and the existing account-union lock cost need benchmarks before enabling large
histories. A measured immutable-receipt cache or revision scheme is a separate
optimization, not an assumed performance guarantee.

Even a ready result does not establish complete upstream history. Older legacy
window pagination, missing historical pairs, futures retention limits and caches
that were already incomplete need their own coverage/reconciliation acceptance.
Financial identity publication, input installation and coordinated reverification
now have executable commands. Preparation still does not accept upstream coverage
or activate the provider. All lifecycle drains, upstream coverage acceptance, native runtime
verification and activation remain separate gates. The focused tests are
authored but have not run in this environment; no migration or activation was
executed.
