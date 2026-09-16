# Questrade legacy financial publication admission

The direct Questrade account processors and source snapshot methods now join the
real legacy migration permit. This slice is implemented with authored behavioral
tests, but the tests have not run in this environment. Native readiness remains
false. It complements the [credential session](provider-questrade-legacy-credentials.md);
it does not activate a native writer or provide a full lifecycle command.

`QuestradeItem::LegacyAccess.with_account` reloads the original provider account
under its original item, verifies its remote account ID, rejects scheduled item
deletion and checks the current financial link's family. A dual link also needs
the exact external account, connection, migration control and account mapping.
An active credential session rechecks its original item, credential and Sync
context at admission.

`with_publication(source, expected_account:, expected_context:, verifier:)` opens
a short savepoint and takes Account, Item, source, ExternalAccount and
AccountProvider locks with NOWAIT. It rechecks the selected financial account's
family, currency, accountable identity, owner and status, plus the original link
UUID/revision and source identity. Missing owners, pending deletion, changed
context or lock contention propagate as ownership/busy denials. A caller's
optional verifier runs against the fresh source and locked financial account
before the local write.

Processors capture the source data and link context before resolving securities.
Security resolution and synthetic cash security lookup occur outside publication
transactions. A replaced link, changed remote ID or changed cache cannot redirect
the result of that work. Holdings retain their original external-ID formula,
fractional quantities, cost-basis protections and `delete_future_holdings: false`.
Cash holdings retain their currency and date-scoped identity. Existing activity
signs, dates, journal handling and synthesized entry identities are unchanged.

A trade and its commission are written within the same publication savepoint.
Counters advance only after that savepoint succeeds. Ordinary malformed rows
retain the existing partial-processing behavior; ownership and busy denials are
always raised. `ActivitiesProcessor` additionally accepts
`publication_verifier:` and `raise_on_error: true`, allowing a delayed request to
retry a failed row without claiming that all local publication completed.
Previously committed rows replay through the existing provider import identities.
This strict option does not reinterpret deliberately unsupported activity types
as complete financial coverage.

Balance and anchor updates share one publication savepoint, and an unsuccessful
anchor result rolls back the financial balance. The account-complete broadcast
runs only after commit. Security and provider HTTP work do not occur inside that
savepoint.

The importer captures source/cache/link context before each balance, position or
activity read, then validates it before staging the response. Per-currency cash
and total equity are stored together. Existing and new discovery snapshots join
the item permit; an existing source cannot adopt a different remote identity.
Unlinked snapshots remain available for account setup without publishing finance.

`with_snapshot(source, expected_context:, verifier:)` provides the same locked
source boundary, with a financial account when linked. The activities snapshot
method accepts `mark_synced: false` to stage raw evidence without advancing
`last_activities_sync`. Its default remains true for existing callers. A delayed
request must construct its processor after staging and commit its completion
receipt/progress only after strict processing succeeds. The context digest
intentionally excludes scheduling fields such as the pending flag and durable
request document; the request verifier owns their revision and original-Sync
checks. Scheduling itself is outside this helper's authority.

The new real-session tests cover all direct entrypoints under refused ownership,
security/publication transaction boundaries, migration and row-lock contention,
link replacement, source drift, verifier denial, snapshot progress preservation,
trade/commission rollback and replay, protected holding cost basis, balance-anchor
rollback, and public importer relinking during HTTP. Existing rollback-based
processor fixtures replace only the physical migration permit; ownership reads
and publication savepoints remain real. No runtime, migration, readiness or
cutover acceptance is claimed by those unrun tests.
