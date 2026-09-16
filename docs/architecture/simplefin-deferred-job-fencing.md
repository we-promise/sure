# SimpleFIN deferred job admission

The three existing deferred jobs now hold a shared
[`LegacyWriterFence`](../../app/models/provider/account_data/legacy_writer_fence.rb)
permit for the current owning item before reading payloads, constructing clients,
mutating source state, or scheduling subsequent work. These are implementation
changes with unrun tests; they do not activate native SimpleFIN or establish that
its migration lifecycle is complete.

- [`SimplefinHoldingsApplyJob`](../../app/jobs/simplefin_holdings_apply_job.rb)
  accepts an originally captured, signed holdings request. It verifies the exact
  family/item, financial account/link, payload fingerprint, source policy and
  originating Sync ancestry before processing, and again before each holding write.
  Holdings processing and ordinary failure diagnostics retain the permit.
- [`SimplefinItem::BalancesOnlyJob`](../../app/jobs/simplefin_item/balances_only_job.rb)
  constructs the importer from the admitted item, leaving transport construction
  to that importer's admission boundary. It preserves discovery's best-effort
  ordinary-error handling and refreshes the current item/family under admission.
  It still leaves `last_synced_at` unchanged so the next full sync imports history.
- [`SimplefinConnectionUpdateJob`](../../app/jobs/simplefin_connection_update_job.rb)
  receives family/claim UUIDs referencing a previously prepared encrypted
  [credential claim](simplefin-credential-claims.md). Credential admission and a
  dedicated session lock protect the single-use exchange and installation.
  Both the claim wrapper and HTTP transport disable retries. The job overrides
  inherited deadlock retry with discard and disables Sidekiq retries, including
  for unexpected failures after claiming the token. Unexpected exceptions still
  propagate. Claim errors and diagnostics omit credentials and response bodies;
  argument logging is disabled. Ordinary account reads keep their retry behavior.

`Busy`, `OwnershipChanged` and `InvalidSource` escape the jobs' ordinary recovery
handlers. A refused job cannot clear flags, render success, or schedule another
legacy operation. The permit is an advisory session lock; these jobs add no row
transaction around HTTP. Queue names remain unchanged. Holdings requests add a
signed `request:` keyword; reconnect uses `family_id:` and `claim_id:` instead of
secret-bearing arguments. Balances-only retains its existing argument shape.

## Originally bound holdings requests

[`SimplefinAccount::HoldingsRequest`](../../app/models/simplefin_account/holdings_request.rb)
is captured through `SimplefinHoldingsApplyJob.enqueue_for(source, sync: ...)`.
Capture takes a short publication lock and records the original financial account
identity/type/currency/status, direct link and AccountProvider revision, remote
account ID and processing-input/credential-revision digest, holdings-policy revision, writer epoch,
and Sync ancestry. The token contains identifiers and a digest, not the raw
holdings payload or credentials. A signature is input evidence, not authorization:
execution must still obtain the live legacy permit and revalidate current state.

The importer and holdings backfill task use this entry point. Each changed
snapshot receives its own request; an older request cannot silently consume a
newer cached payload. Unchanged payloads do not enqueue additional importer jobs.
Capture skips unlinked, non-investment and empty sources. A removed source is a
no-op at execution, but a changed or deleted financial target, changed remote
identity, relinked source, changed policy or cancellation rejects the old request.
Completed originating Syncs and same-family ancestors remain eligible; missing,
failed, cancelled or reparented ancestry does not. Scheduled deletion also rejects
capture and execution.

The processor checks the request before resolving securities, releases financial
row locks for resolution, and checks again inside each holding's publication
savepoint. Concurrent input or ownership changes during resolution therefore
cannot publish into a new target. Each write retains its existing rollback boundary.

Existing ID-only jobs cannot prove their original context and fail for a surviving
source. Deployment must drain or explicitly dispose of them and, where appropriate,
reissue work from an admitted current source. Key rotation that invalidates the
Rails message verifier requires the same explicit reissue; execution does not
manufacture replacement context. Queue disposition and deployment acceptance
remain rollout work. Holdings still use the legacy execution-day `Date.current`;
the request does not establish an immutable observation date or complete native
history handover.

## Remaining lifecycle work

The shared permit excludes the migration drain, not every other legacy writer.
Concurrent relinking, credential edits and source/family transfers need their own
coordinated lifecycle commands. The holdings job now carries its original
source context, while the compatibility balances-only job still carries only
an item ID. That compatibility job validates the current owner at execution but
does not retain its original family or cancellation lineage. No current production
enqueue caller was found for it; outstanding jobs still need explicit disposition.
The reconnect journal now retains the original family/item, credential revision
and writer epoch, with committed intent, confirmed result and installation states.
Confirmed results can resume installation; installed requests retain their original
Sync for queue recovery. Unknown remote outcomes require a new token. The edit page
now offers eligible existing-item retries and audited cancellation of obsolete
requests; delayed jobs cannot revive cancelled claims. Old secret-bearing jobs
still require deployment disposition, and initial-connect requests without an item
need a separate recovery interface. The [claim protocol](simplefin-credential-claims.md)
describes implemented serialization and remaining runtime/lifecycle acceptance.

The named jobs do not cover direct controller/link/unlink/deletion callers or raw
Active Record updates. The [importer and direct resource processor guards](simplefin-legacy-access.md)
are separate cooperating boundaries. Migration must account for all queued/running
jobs before source ownership changes; a legacy job does not become a native one
merely because its source was copied.

[`SimplefinLegacyJobsTest`](../../test/jobs/simplefin_legacy_jobs_test.rb) covers
denied migration states, real competing-session drains, fresh payload/credentials,
reparented and foreign financial links, ordinary failure recovery, nested denials,
token claim/discard behavior and family scoping. These real-commit tests are
separate from existing holdings materialization tests that use fixture
transactions. The [request tests](../../test/jobs/simplefin_holdings_request_test.rb)
and [importer integration tests](../../test/models/simplefin_item/importer_holdings_enqueue_test.rb)
cover signed serialization, stale targets/inputs, Sync ancestry and changed versus
unchanged snapshots. [Reconnect job tests](../../test/jobs/simplefin_connection_update_retry_test.rb)
exercise post-claim failures and actual Sidekiq payload retry configuration;
[claim transport tests](../../test/models/provider/simplefin_claim_retry_test.rb)
cover single attempts and redaction. These tests are authored but unrun. No Ruby
execution, setup, migrations or cutover was performed.
