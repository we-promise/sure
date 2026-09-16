# Family destruction admission

[`Family#destroy`](../../app/models/family.rb) enters
[`Family::LegacyDestruction`](../../app/models/family/legacy_destruction.rb) before
Rails starts dependent deletion or subscription/Plaid callbacks. It enumerates
all 23 reviewed migration-manifest item classes by `family_id`, including
unlinked, hidden, failed and scheduled-for-deletion connections. It does not use
the narrower scheduling inventory or loaded family association caches.

The helper acquires the complete shared lifecycle permit set before opening its
transaction. Inside a savepoint it locks the Family row, then all current family
Users, all current family Accounts, and every admitted legacy item. Users and
Accounts are ordered by UUID; items use manifest-class/UUID order. These child
row locks use `FOR UPDATE NOWAIT`. It refreshes the family, compares the full
current item identity inventory, and revalidates
each migration owner. The Family lock prevents new family references; child locks
prevent existing rows from being removed or reparented after the final check.
A child row already being edited yields `LegacyWriterFence::Busy`. Missing or
changed ownership fails before dependent callbacks. No item may be added to an
already acquired permit set.

The User locks reject an in-flight family transfer before destruction takes its
provider item rows: otherwise the transfer could wait for an item while deletion
later waits for that User. The Account locks also conflict with `FOR KEY SHARE`,
which balance materialization can hold before validating ownership under a User
lock. Using `FOR NO KEY UPDATE` here would leave that cycle open. Both contention
cases fail before Stripe/Plaid callbacks, rather than waiting after a remote
side effect. These locks close those specific cycles; they do not refactor the
legacy transfer or materialization workflows.

Shared `ProviderConnection` rows, retained migration controls/mappings and
`IngestionBatch` rows are checked before destructive callbacks. They already
restrict Family deletion
through the association or database foreign keys. The helper returns `false`
with ordinary model restriction errors instead of allowing Stripe cancellation
or Plaid removal before reaching those restrictions. It does not delete shared
connections or migration history, and does not implement native deletion.
This includes file-only batches whose Import or AccountStatement still owns
captured evidence even when the family has no provider connection. Their source
records and account sync inputs also retain the mandatory batch dependency;
financial evidence retirement remains a separate workflow.

The successful return remains the original destroyed Family instance. A callback
that aborts returns `false`, keeps its model errors, and rolls back earlier
dependent writes even if an already admitted caller continues its outer
transaction. Admission errors propagate without clearing deletion state.
Ordinary exceptions from callbacks retain their original class. Empty inventories
need no physical advisory locks and can run in a caller transaction; nonempty
inventories require prior admission outside that transaction.

This is a bounded ownership guard, not an atomic remote deletion protocol.
Existing Stripe/Plaid callbacks still run within Rails' destruction transaction;
later callback failures cannot undo their remote effects. The family-wide item
inventory is capped at 1,000 and fails closed above that bound. User/provider
reparenting paths still need compatible lock ordering and lifecycle admission.
Direct financial Account destruction can affect transfer counterparties and
retained source/sync evidence, so its owner inventory is separate. The financial
reset service performs bulk deletion outside this method. Asynchronous SnapTrade
cleanup still needs fresh ownership admission when it later constructs a client;
Indexa's cleanup also reads credentials despite its remote delete placeholder.
The helper does not claim to close those gates.

Focused real-commit/concurrency tests cover the complete provider inventory,
remote-callback admission, blocked owners, existing shared-history restrictions,
concurrent insertion/reparenting, busy User/item rows and Account FK locks,
callback rollback, nested transactions and stale association caches. They have
not run in this environment;
no migrations, setup, or provider activation were executed.
