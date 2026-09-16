# Brex preparation and ownership handover

The shared cutover coordinator now registers Brex's retained-history verifier.
Its source-selection preparation also recognizes Brex's transaction and balance
resources. These paths and their behavioral tests are written but unrun. Brex's
native readiness remains false; no migration, live copy or cutover has run.

Preparation keeps the existing company-card identity, `card_primary`, alongside
each cash account. Physical cards are retained inside the aggregate's evidence.
The shared copier preserves the original account links and financial UUIDs;
identity publication supplies signed evidence without rewriting ledger values.
Single-link accounts acquire missing transaction/balance source policies before
identity publication. Accounts with several links require explicit choices.
Existing choices, including a different provider for balances, remain unchanged.

Final handover holds the exclusive legacy permit, checks drained legacy work,
locks the original ownership and financial inventory, and repeats copy, identity
and auxiliary verification. The [Brex history contract](brex-cutover-history.md)
then checks retained account aggregation and cached financial versions. A last
successful sync cannot excuse cached transactions that were never published.
Unresolved history refuses activation instead of silently accepting a gap.

Only after verification, the command installs each account's
`brex_initial_history_start` and commits native ownership, writer epochs, the
preparation receipt and one pending Sync in the same transaction. The first Sync
has no connection-wide date override. Those dates bound requests; they do not
claim complete upstream coverage. A failed transaction rolls back the handover.
A queue failure leaves the committed Sync available for the same command to
dispatch again after releasing its database transaction and legacy permit.

The [coordinator tests](../../test/models/provider/account_data/brex_migration_cutover_test.rb)
exercise actual legacy processing, copying, preparation, signed identity
publication, cutover and the production native Syncer with fake HTTP responses.
They check cash and company-card identity, source-policy preservation, user
protections, cached-data refusal, readiness, atomic installation and dispatch
recovery. They complement the narrower history and request-window tests.

The [shared settings editor](provider-native-configuration.md) accepts Brex's
static token through an explicit adapter policy. It preserves the original
endpoint, old credentials and migration archives. Changing the endpoint needs
its own transition; it is not an ordinary field update.

The [direct legacy publication guards](brex-cutover-history.md) and
[lifecycle commands](brex-lifecycle-admission.md) now join ownership admission.
They refuse stale settings, picker submissions and financial publication after
quiescence. The existing manual-sync route resolves the exact migrated owner.

Registration is not operational acceptance. Unresolved cache dispositions, native
account discovery/setup and disconnection, rollback after native publication,
upstream coverage and executable acceptance remain migration requirements. Run
the behavioral and concurrency suites in the project's Ruby/PostgreSQL environment
before considering readiness.
