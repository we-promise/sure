# Retaining logos when compatibility rows are retired

The [auxiliary copier](../../app/models/provider/account_data/auxiliary_copier.rb)
has a separate [retirement path](../../app/models/provider/account_data/auxiliary_copier/retirement.rb).
It verifies the original completed logo capture and removes only its legacy
ActiveStorage attachment row. The native ProviderConnection attachment continues
to reference the same blob. No upload, blob replacement, purge, variant deletion,
attachment callback or new archive capture occurs.

This is one input to the admitted migration-retirement command. It does not
authorize account or item deletion by itself, enable a provider, or establish
financial-history acceptance. Existing copy and retained-verification entrypoints
continue to require an unused disabled connection before cutover.

The caller uses one `AuxiliaryCopier.for(control:)` instance and holds the actual
exclusive legacy-item permit throughout these first two steps:

1. `prepare_retirement(family:)` runs outside database transactions. Short locked
   checks authenticate the original item archive, native cutover and preparation
   receipt, original logo checkpoint, source/target attachment metadata and blob
   metadata. It compares every original storage range with the encrypted archive,
   then repeats the database checks. The result is a deeply frozen, signed,
   JSON-safe receipt containing identities and fingerprints, without blob keys,
   filenames, metadata or bytes.
2. `apply_retirement!(family:, receipt:)` runs inside the final retirement
   transaction. It requires the same prepared copier and uninterrupted permit,
   repeats database-only checks, and deletes the exact original legacy attachment
   with `delete_all`. The surrounding command must remove its admitted legacy
   rows and persist the receipt in the same transaction. Outer rollback restores
   the attachment, allowing a retry under that permit.
3. A fresh instance can use `verify_retirement!(family:, receipt:)` after the item
   is absent. It authenticates the receipt and verifies the original checkpoint
   and encrypted archive fingerprints, target attachment, blob metadata and
   absence of the legacy attachment. It does not read remote storage or require
   later native execution to be idle; prepare/apply still require idle ownership.

All operations pin the original family, control, connection, copy run and item
mapping. Missing/replaced checkpoints or archive rows, changed target/source
metadata, incomplete copies and foreign or tampered receipts refuse. Missing
logos have explicit signed zero-chunk receipts. Native credential revisions may
advance: the original auxiliary copy context remains pinned to its preparation
receipt instead of being rebuilt from current credentials.

Preparation performs a full bounded sweep, up to the existing 32 MiB logo limit
and its original number of ranges. It does **not** have the eight-range budget of
`verify_retained_page`; small original chunks can require many requests. Database
archive verification also reads the original bounded archive. Storage reads never
run inside a database transaction. The database-only apply cannot detect an
out-of-band storage mutation after the sweep; the exclusive permit fences
participating legacy writers, not arbitrary storage-service writes. Post-retirement
verification proves retained archive bytes and target metadata, not fresh storage
availability. These performance and storage behavior limits need runtime acceptance.

IBKR inherits the API while retaining its original `legacy_ibkr_auxiliary` stream,
archive formats, idempotency keys and signer derivation. This adds no IBKR cutover
authorization; its pre-native archive remains ineligible for retirement.

The focused tests cover actual Up copy/preparation/cutover followed by byte
verification and attachment retirement, absent logos, outer rollback/retry,
uninterrupted permits, storage/metadata/archive drift, receipt tampering and
item-absent replay. The IBKR regression checks unchanged original compatibility
and refusal before native ownership. Tests are authored but unrun; no migration,
cutover, retirement or storage operation has been executed against user data.
