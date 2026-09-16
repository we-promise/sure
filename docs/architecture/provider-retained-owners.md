# Retaining provider ownership after compatibility retirement

Source ownership must survive removal of legacy item/account rows without changing
financial account IDs, AccountProvider IDs or historical source-policy bindings.
An original dual link keeps its legacy type/UUID as well as its shared counterpart.
The archived source establishes provenance; current links and source policies
continue to determine financial authority.

## Implemented preparation and readers

[`RetiredOwner`](../../app/models/provider/account_data/retired_owner.rb) records a
small immutable `retained_owner` projection on each connection and external-account
migration mapping. It contains only source/family/connection/mapping identities,
the original copy run/version and its authenticated snapshot checksum. It contains
no credentials, raw payloads or financial account ownership.

`RetiredOwner.prepare!(control:, family:)` starts outside a database transaction,
acquires the actual exclusive legacy writer permit and locks the current native
connection, control and source inventory. It requires an original native cutover
receipt, a verified quiesced copy, and settled legacy/native sync work. It captures
all connection/account witnesses atomically, within 1,000 mappings and 32 MiB of
decoded archives. Every source row must still exist in the expected family/parent.
The original encrypted archive is authenticated before writing its witness.

The lower-level `capture!(mapping:, family:)` requires an existing transaction and
the same real exclusive permit. Neither entry point deletes rows, marks a control
retired, changes a link/policy, or rewrites migration evidence. Repeating capture
checks the same projection and preserves it.

When a source row is missing, `Ingestion::SourceOwners` can resolve its original
identity only through a matching witness on a retired control. It reauthenticates
the bounded original archive and compares archive headers before and after reading.
A present row with a contradictory parent/family is refused. The original archive's
financial binding never replaces today's AccountProvider and policy authority.

Source-policy selection and unlinking lock the retained mappings, controls and
archive batches, then recapture their entire owner graph. This supports both
original dual links and subsequently created native-only links. Original policy
bindings remain immutable. The additive
[ownership migration](../../db/migrate/20260916001000_retain_provider_source_owners.rb)
also permits a new policy revision for a retired dual source only when both source
witnesses exactly match their shared counterparts. It freezes the captured mapping
identity and copy evidence and refuses rollback while any witness remains.

`Sync.for_family` includes original legacy Sync owners through these retained
connection witnesses, using the manifest allowlist and exact family/control/copy
projection. History lookup does not create a legacy model or enqueue work. The
original Sync IDs, types, statuses and parent/child relationships stay unchanged.

## Physical retirement and saved URLs

[`MigrationRetirement`](../../app/models/provider/account_data/migration_retirement.rb)
now composes ownership capture with an explicit physical-removal command. Its
current reviewed dispositions are Up, Mercury and Brex; provider readiness stays
unchanged. It requires native cutover, idle work, an exact source/mapping inventory,
unchanged original source values and [retained logos](provider-logo-retirement.md).
It removes only the admitted legacy account/item rows without callbacks and records
a signed completion receipt in the same transaction. Original links, policies,
financial rows, Syncs, mappings and archives remain. Repeated calls verify the
receipt and absent-source evidence without constructing a deleted legacy item.

The [shared legacy-route resolver](../../app/models/provider_connection/legacy_route.rb)
keeps the reviewed providers' saved edit, setup and manual-sync member URLs usable
after retirement. It checks the current family/admin and locks authenticated
ownership proof before routing. Manual sync uses the shared connection and its
existing scheduling behavior; connections needing attention cannot enqueue work.
Old update, delete and setup submissions receive a destination for a fresh shared
form. Their old parameters are never applied to the native connection. Existing
legacy rows continue through their established controllers and lifecycle checks.
Collection pickers and legacy show URLs are outside this compatibility path.

The [all-provider retirement inventory](provider-retirement-inventory.md) records
the remaining dispositions before expanding removal beyond the reviewed providers.
Ordinary legacy `destroy!` is unsuitable: its callbacks can remove shared links,
destroy Sync history, revoke upstream access or purge blobs.

Plaid/SimpleFIN direct account pointers require an explicit shared-link proof and
pointer transition. Shared logo attachments use verified retention of the
same blob and a recorded disposition of the old attachment, without purging it.
Questrade activities and SimpleFIN credential claims must retain their settled
request disposition. Remaining old item URLs and provider-specific lifecycle
surfaces also need an explicit native routing policy. These requirements must
precede expanding actual removal to those providers.

The focused SourceOwners, policy-guard and family-history tests exercise real copied
fixtures, source-row removal, identity preservation, missing evidence, altered
archives and family isolation. They remain unrun because Ruby/Bundler is unavailable
in this environment. No migration, live cutover or physical retirement was executed.
See [implementation status](provider-implementation-status.md) for overall progress.
