# Original historical command source bindings

Status: implementation and behavioral tests written, but tests, migration and
backfill have not run. This metadata change does not activate a provider, publish
financial history or authorize account deletion.

IBKR historical commands capture both a historical-balances policy and an optional
balances policy. Those policies can belong to different integrations for the same
financial account. Discovering only the primary policy can omit a source owner
needed for lifecycle admission.

[`SourceBinding`](../../app/models/ingestion/historical_balances/source_binding.rb)
projects the original typed command into the existing `IngestionBatch.source_binding`
column. The `historical-command/v1` object has exactly ten fields: format, financial
account, AccountProvider, external account, resource, primary policy, publication,
balances policy, opening-anchor policy and source batch. An explicit null secondary
policy means it was absent at capture; an empty object means routing is unknown.
Neither state is filled from today's account links or selected policies.

## Capture, retry and older rows

New `IbkrPlan` commands capture this projection before persistence. Encoded payload
size, depth and node limits also apply to fresh captures, so the normal capture
path cannot knowingly create a command too large for subsequent verification.
Both existing-command return paths index and verify the saved command. The Writer
does the same after its existing command lock and before applied-command replay
or financial writes. It reloads its AR instance and retains the admitted original
payload. This is transparent metadata indexing during normal reuse.

Cold older commands can be indexed through the explicit
`provider_data:index_historical_bindings` task with required `FAMILY_ID`, optional
`AFTER_ID`, and `LIMIT` from 1 through 100 (default 25). Each row commits separately;
a later failure leaves completed rows indexed and retries skip them. A terminal
page checks family-wide coverage, including rows before the supplied cursor.
Running this task is an operational migration step; it has not been run here.

Indexing reads a fresh persisted row under `FOR UPDATE NOWAIT`; read verification
uses `FOR SHARE NOWAIT`. It checks scalar headers and stored byte sizes before
loading the encrypted payload, then validates the decoded original command and
exact projection. A busy row requires retry. Only `source_binding` changes: UUIDs,
ciphertext, timestamps, status, source policy references and financial values stay
intact. The helper does not read current accounts, links, policies or credentials.

The migration's database guard prevents replacement of original command headers
or ciphertext. It permits the one-time fill of an empty binding and thereafter
prevents binding changes. Status, application time, error code and update time may
still change through existing execution paths. Empty bindings remain legal during
the incremental rollout, but discovery refuses to treat them as indexed.

## Discovery and unresolved ownership

[`Account::Destruction::Sources`](../../app/models/account/destruction/sources.rb)
reads the scalar projection without decrypting or modifying captures. It follows
both policy references, verifies their family/account/resource ownership, and
follows the original equity snapshot batch. Secondary policy ownership may belong
to a different provider from the primary historical policy.

An original policy UUID remains in the projection even if that policy has been
deleted. Such a capture is indexed but its owner remains unresolved; discovery
refuses it. Indexing cannot reconstruct deleted policy ownership or silently adopt
a replacement policy. Family-wide checks reject unknown or malformed historical
bindings before target filtering so a detached command cannot disappear from the
inventory. Routing and policy-text indexes support these scalar lookups.

## Limits and verification

Stored ciphertext is limited to 48 MiB, decoded command context to 32 MiB, binding
JSON to 16 KiB, structure to one million nodes and depth to 64. Rails decryption,
decompression and deserialization occur before decoded bounds can be checked.
Historical decompression therefore does not have a strict allocation bound.

Index completeness is coverage, not original-payload integrity verification. SQL
cannot decrypt an original command; callback-bypassing writes could insert a
well-shaped but false initial projection. `verify!` compares the projection to the
original. A future lifecycle command must verify relevant originals after admitting
all source owners and before mutation; this read-only inventory is not authority.

The behavioral suite covers real Plan capture/retry and Writer publication/replay,
different-provider secondary ownership, deleted policies, strict identity checks,
bounds, nonblocking lock contention, original immutability, partial backfill commits
and cursor coverage. Ruby/Bundler are unavailable, so these tests remain unrun.
See [source discovery](provider-account-source-inventory.md),
[historical balances](provider-historical-balances.md) and
[implementation status](provider-implementation-status.md).
