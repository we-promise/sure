# Publishing transaction observations collected before account setup

The current working tree includes a bounded first-publication command in
[RetainedTransactions](../../app/models/provider/account_data/retained_transactions.rb).
Its tests are authored but unrun because Ruby is unavailable. This does not
activate a provider or establish migration acceptance.

Connection transaction feeds can receive data for unlinked accounts.
[TransactionSync](../../app/models/provider/account_data/transaction_sync.rb)
captures and seals the complete connection change set, then sends its unlinked
children to [UnpublishedObservations](../../app/models/ingestion/unpublished_observations.rb).
Those rows keep canonical input identities and their latest original batch,
with no financial account or posting. Successful promotion advances the
connection cursor and sets `transaction_backfill_required` for an account with
retained changes. [GenerationAccounts](../../app/models/provider/account_data/generation_accounts.rb)
refuses subsequent linked transaction generations until that requirement has
been resolved. Merely linking an account or resetting an account cursor would
not replay the connection's already consumed history.

The setup command authorizes the user and establishes the current account link
and source selection. Inside that same database transaction it calls
`RetainedTransactions.new(external_account:, sync:).call`, supplying the fresh
pending provider Sync that it will enqueue after commit. The replay command
rechecks an idle native connection, locks the current financial account and
source binding, and verifies its bounded inventory of original applied
transaction-generation children. A missing original observation, incomplete
generation, prior financial binding, ambiguous ordering, invalid payload or
changed observation pointer refuses publication. No provider request, price
lookup or checkpoint update occurs.

Successful replay creates an encrypted provider transaction batch in the
separate `retained-transactions:<external UUID>` scope. Its binding captures
the new link and policy. Its evidence contains the original batch/generation
IDs, canonical payload digests and original observation pointers and states.
The original batches, generation contexts, source bindings and checkpoints
remain unchanged. The new batch is a complete local change set; its coverage
explicitly says upstream history is incomplete and pending absence is not
authoritative. It cannot authorize absence pruning or advance upstream coverage.

[LedgerWriter](../../app/models/ingestion/ledger_writer.rb) performs the actual
first financial publication. [SourceRecord](../../app/models/source_record.rb)
allows the previously NULL account binding only under the current captured
selection. Observations preserve their UUIDs and input identities; their latest
batch pointer advances to the new publication. Secondary source selections
still produce observations only. Existing same-provider financial identities
without the expected mapping are refused. Ordinary ledger protection and manual
duplicate rules remain those of the existing writer.

Latest withdrawn observations remain exact tombstones and create no entries.
For a posted record with an explicit pending predecessor, a still-active retained pending
record is published first. The existing mapped transition then keeps one Entry
UUID and durable alias evidence. Two posted identities claiming one predecessor,
or a retained predecessor that is already withdrawn or nonpending, require
explicit reconciliation. The command does not guess a former pending value or
temporarily restore old source state. A later pending alias replay follows the
normal mapped-alias suppression path.

Receipt creation, financial writes, first source binding and clearing the
backfill flag share one savepoint. Failure rolls them all back. An identical
retry returns the original applied receipt under the same current binding.
Changing source authority later or relinking previously bound history requires
a separate reconciliation command; this API does not adopt that history.

The implementation caps observations and distinct transaction identities at
10,000, original account batches and applied connection generations each at 256,
stored page bytes at 32 MiB, stored
generation-context bytes at 32 MiB and decoded canonical page bytes at 32 MiB.
It refuses rather than partially publishes above these bounds. Existing Rails
encrypted-document decoding can allocate a compressed historic value before
the decoded-size check; this is not a hard decompression-memory guarantee.
The transaction duration and practical limits still need runtime measurement.

## Limits of setup and other retained resources

- [RetainedRow](../../app/models/provider/account_data/retained_row.rb) verifies
  original migration archives. It does not normalize their raw provider caches
  into canonical observations. A copied unlinked account keeps its original
  NULL copy-time financial binding. Setup must separately establish an explicit
  provider cache disposition and must not replace that original binding with
  today's new link. Returning nil from replay means no canonical transaction
  replay was needed, not that a legacy archive has been consumed.
- Ordinary account-scoped streams currently fetch selected linked accounts;
  they do not use the connection-generation unpublished path. Their initial
  history window still needs the provider's own setup/cutover contract.
- Connection activity feeds can retain activities, but do not currently set
  this transaction backfill barrier. Securities resolution, activity groups,
  pending semantics and an activity replay barrier require a separate command.
- Holdings, balances and historical balance/opening-anchor commands retain
  different snapshot and authority contracts. This transaction command cannot
  replay or certify them.

[Focused tests](../../test/models/provider/account_data/retained_transactions_test.rb)
use the real TransactionSync capture/seal/promotion and LedgerWriter paths for
latest values, aliases, removals, secondary authority, immutable original
evidence, retries, rollback and bounded refusal. No external provider calls,
migrations or cutovers were performed.
