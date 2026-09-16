# Mercury lifecycle admission

This working-tree slice routes the existing Mercury browser workflows through
provider-owned commands. It does not enable native Mercury, execute a migration,
or establish end-to-end acceptance. Ruby and browser rendering are unavailable;
the behavioral tests described below are authored but unrun.

[`Lifecycle`](../../app/models/mercury_item/lifecycle.rb) performs fresh active
family-admin checks and enters the existing item writer permit before discovery,
setup, linking or disconnect. Settings updates use the exclusive item permit to
drain in-flight legacy HTTP before changing its credentials. Remote account reads occur
outside database transactions. A keyed fingerprint of the original connection,
credentials, endpoint, history setting and deletion state is compared after HTTP
and again under the short publication lock. No API secret is placed in a cache
key, form token or diagnostic.

The account pickers and setup form carry a 15-minute signed
[`Selection`](../../app/models/mercury_item/selection.rb) identifying the exact
family, item, flow and existing financial account, when applicable. Link POSTs
require an explicit item and valid selection; the GET convenience of selecting
the sole credentialed item does not authorize a later implicit POST. Credential
or endpoint changes invalidate older choices and their cache namespace. Setup
keeps existing local discovery behavior, new links start at zero before provider
sync, and setup completion retains the selected source balance and subtype.
Existing-account links additionally require fresh owner/full-control access.

Local mutations use savepoints and nonblocking locks. Existing financial Accounts
are locked before the item, then the acting User and selected source/link rows.
A failed link or disconnect callback rolls back its local writes. Disconnect
preserves the financial Account and removes only links belonging to the selected
Mercury item. It refuses copied dual links and any retained source-policy rows;
retiring those sources requires a separate, evidence-preserving disposition.
The direct `destroy_later` and `unlink_all!` model entrypoints also enter the
legacy permit, so they cannot set deletion flags or unlink after ownership moves.
Direct `unlink_all!` retains its existing per-source result/error behavior; the
browser disconnect command uses one atomic savepoint instead.

[`SyncRequest`](../../app/models/mercury_item/sync_request.rb) keeps the old manual
sync route usable after ownership transfer. It captures the routing decision,
then rechecks the fresh item, active admin, control, exact connection-role mapping
and target connection under ownership locks. Legacy ownership queues the item;
native ownership queues only the mapped shared connection. Transitional ownership
or a changed routing decision refuses without falling back to another writer.

The [real lifecycle tests](../../test/models/mercury_item/lifecycle_test.rb),
[routing tests](../../test/models/mercury_item/sync_request_test.rb) and
[GET-to-POST tests](../../test/controllers/mercury_lifecycle_test.rb) exercise
normal setup/linking, stale credentials/forms, actor revocation, migration denial,
rollback, actual drain exclusion and native routing. Existing transactional
controller rendering tests use an explicit mocked-transport seam; the new suites
use real commits and the actual permit.

Remaining boundaries include native credential/settings management, connection
retirement with retained policies or copied links, direct raw Active Record
updates/destruction outside the declared lifecycle, and the mixed-provider
pending-reconciliation behavior documented in
[legacy writer fencing](mercury-legacy-writer-fencing.md). This slice does not add
cross-provider transaction deduplication or PDF publication.
