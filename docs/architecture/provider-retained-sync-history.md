# Retained legacy Sync history

`Sync.for_family` includes an original legacy item owner after its compatibility
row is removed when `Family::ProviderSyncables#retained_history_scope` finds its
exact retained connection mapping. Live legacy rows and shared connections keep
their existing history scopes.

The additional query accepts only item types in `MigrationManifest`. It requires
the same family, provider, control and connection; a retired control; a verified
version-one copy; the original native cutover receipt; and a complete
`retained-provider-owner/v1` witness matching all thirteen captured fields. The
whole JSON projection must match, including the original item UUID, mapping UUID,
checksum and copy run. An absent witness, changed cutover copy receipt or another
family does not expose the old owner's Syncs.

`RetiredOwner.prepare!` captures the witness while the original rows still exist,
under the migration permit and ownership locks, after authenticating the copied
archive. The history query uses that immutable routing witness without decrypting
the archive on each page. Financial ownership consumers separately authenticate
retained archive evidence before using a missing source; a history match grants
no financial write authority.

The query returns the original Sync rows. Their UUIDs, owner type and UUID,
statuses, timestamps, errors, parent and children remain unchanged. It creates no
legacy Active Record object and does not convert old work into a native Sync.
Scheduling still selects the live native connection after retirement. Witness
capture itself neither removes source rows nor authorizes row or table deletion.

The focused nontransactional tests use actual Up copy, preparation, cutover and
witness capture, followed by callback-free fixture removal of the compatibility
account and item. They cover preserved history and ancestry, live-row behavior,
missing witnesses, retirement state, family isolation, changed copy receipts and
unchanged scheduling. The generated native Sync is settled only as fixture state;
the tests make no claim that a native provider fetch ran. Ruby is unavailable in
this environment, so these tests are authored but unrun.

Related: [migration matrix](bank-data-provider-migration-matrix.md),
[native account setup](provider-native-account-setup.md).
