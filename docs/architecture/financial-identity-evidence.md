# Retaining migrated financial identities

Status: evidence capture, a resumable publisher, final inventory checks, model
validation, resolver integration and PostgreSQL guards are written with unrun
tests. The publisher is an internal command; it is not wired into operator tasks
or cutover. No schema migration or data transfer has run. This is a foundation for the
[migration plan](bank-data-provider-migration-matrix.md).

## Permanent evidence and current observations

Migration must adopt existing Entry UUIDs without changing their financial values,
protections or compatibility identities. `SourceRecord.ingestion_batch_id` records
the latest observation and advances during native sync. It cannot also serve as
the permanent proof of which historical Entry that source originally identified.

`EntrySource` therefore retains `bootstrap_batch_id`,
`bootstrap_external_account_id`, `bootstrap_identity_role`,
`bootstrap_entryable_type` and `bootstrap_identity_state`. The role is either
`current` or `retired_alias`; both mappings use the existing posting role. An old
pending alias identifies the same posting and must not count as independent live
corroboration when the current provider record is withdrawn. The retained type and
identity state bind the original delegated financial row, compatibility IDs,
pending flags and explicit aliases. They exclude financial amounts, descriptions,
categories and user protections, which can legitimately change after capture.

The batch has origin `migration`, stream `legacy_financial_identities`, and exact
external-account scope. Its mode is unknown and completeness is false. It has no
invented Sync, provider coverage, native writer epoch or upstream cursor.

`Ingestion::LegacyIdentityEvidence` validates the signed, encrypted capture and
exact family, account, external account, kind and input identity. Its payload keeps
the typed financial snapshot and checksum, current and explicit retired IDs, the
original account link, copy run, archive checksum and captured resource bindings.
Later native resolution validates this permanent proof even when the observation
references a newer provider batch. The original financial checksum is an audit of
capture, not a rule prohibiting legitimate later financial changes.

The resolver returns an explicit retired-alias result without a writable Entry.
Replaying that alias cannot change a booked transaction or fall through to create
a new one. Missing, conflicting or deleted posting mappings fail closed. Exact
legacy Plaid-only IDs remain supported without rewriting `entries.plaid_id`,
`external_id`, `source` or protected transaction metadata.

## Capture boundary

The trusted caller selects and reruns the reviewed provider planner. A submitted
JSON document alone cannot authorize identity publication. `seal` requires an
existing transaction and the actual exclusive legacy-writer session permit. It
checks the disabled connection, zero writer epochs, verified quiesced copy run,
absence of native activity and current account/source-policy context.

Locks follow control, connection, original financial Account, ExternalAccount and
retained AccountProvider order. The account link is compared with its initial
identity before source-binding capture can acquire additional locks. The legacy
account archive must still match the source, and financial rows must match every
reviewed attribute. Financial Entry and Transaction/Trade locks use NOWAIT because
manual pending merges may lock Entries in a different order. Contention raises a
retryable capture error; the caller must roll back and prepare a fresh plan.

Archive reconstruction is limited to 32 MiB and 1,024 chunks. Plans have at most
500 financial rows and a 96 MiB serialized bound. These limits are admission
ceilings, not a throughput claim; realistic encrypted-payload memory, contention
and multi-account inventory benchmarks remain required.

`seal` itself writes no evidence. `Ingestion::IdentityBootstrap` selects the
trusted planner, replans under that admission boundary, and atomically creates the
captured batch, source records and posting mappings. It marks the batch applied
and advances a dedicated checkpoint in the same transaction. New records validate
against the captured batch within that transaction; later resolution requires
applied state. It never saves an Entry, Transaction or Trade or calls the ordinary
financial writer.

## Resumable publication and verification

The internal interface accepts a persisted migration mapping and an authorized
family. It selects the specialized Plaid planner or the shared manifest-backed
planner for the other providers; it accepts no caller-supplied plan or cursor.

```ruby
bootstrap = Ingestion::IdentityBootstrap.new(
  mapping: external_account_mapping,
  family: authorized_family,
  page_size: 100
)
result = bootstrap.run
```

Each call commits at most one bounded page. The encrypted checkpoint uses stream
`legacy_financial_identities` and the exact ExternalAccount scope. It retains the
copy run, source and account/link context, resource bindings, pinned page size,
cursor, batch sequence and counts. It does not replace the row copier's progress
or any upstream provider cursor. A caller resumes by constructing the same command
and calling `run` again, with the same page size (1–500).

Capture creates only missing identities. Existing identities must retain their
exact original signed proof and current/alias mapping; economic or descriptive
edits do not replace that evidence. Partial, orphaned, changed or conflicting
mappings stop the page. A failed page rolls back evidence and progress together;
the next attempt replans against committed state. Existing evidence without its
original checkpoint is an error, not permission to begin a replacement capture.

After capture reaches the end, phase `verify` starts from the beginning. It checks
each current row against its original proof without creating mappings. At the end,
forward and reverse inventory queries check every current candidate and retained
mapping, exact delegated type/row ownership, source identity, pending metadata and
aliases. The SQL compares JSONB identity state directly, using the same fields as
the signed Ruby capture. Counts additionally detect rows moving behind the sweep
cursor. An empty inventory follows the same capture/verification protocol.

`restart_verification!` restarts that sweep after capture has finished.
`restart_capture!` also restarts capture when a late candidate needs adoption.
Both retain prior batches, mappings, captured totals, batch sequence and pinned
context while resetting verification progress; neither permits changed source
ownership or rewrites earlier proof. Repeating `run` in phase
`verified` rechecks context and terminal inventory and returns without rewriting
the checkpoint.

`verified?` means this scoped protocol completed. It does not activate an adapter,
transfer a provider cursor or establish deployment-wide quiescence. The Account
lock prevents new Entry inserts through its foreign key during the terminal check,
but these read-committed queries do not freeze every existing financial row or
prevent later edits. The result explicitly records
`requires_cutover_reverification: true`. Final copy, identity, auxiliary and cursor
proofs must be coordinated again with all legacy and lifecycle writers drained
before cutover. UUID pagination alone is never a change feed.

During a publication transaction, `LegacyIdentityEvidence.with_validation_cache`
reuses one validated, recursively immutable batch proof and its identity index.
The cache is limited to the same batch object, payload object, captured context,
database connection and transaction. Batch status and stored payload size are
still read from the database on every validation; reloaded or changed inputs miss
the cache. No proof cache survives the transaction.

## Storage and operational acceptance

The additive migration `20260915160000` adds exact composite ownership foreign
keys and two database triggers. Captured bootstrap payload/context cannot change,
applied batches cannot be rewound, and permanent mapping identity cannot be
rebound or removed through updates. Existing Entry deletion may detach its live
foreign key and mark evidence inactive while preserving the original Entry UUID
and bootstrap provenance. Schema rollback refuses while retained bootstrap
mappings exist.

Rails `schema.rb` does not preserve the custom PostgreSQL functions/triggers.
An empty database restored only from that file is not equivalent to a migrated
database. Deployment and test-schema restoration must recreate and verify both
`ingestion_bootstrap_capture` and `entry_source_bootstrap_identity` before use.
The user's existing schema edit has not been changed.

### Signing keys and retention

New proofs use a dedicated, explicitly configured HMAC-SHA256 keyring through
`Ingestion::IdentitySigningKeys`. They never derive a signing or verification key
from `SECRET_KEY_BASE` or the Active Record encryption keys. The signature is an
object containing `version: 1`, `key_id` and a lowercase hexadecimal `digest`;
the authenticated message includes the fixed protocol domain, selected key ID
and exact typed proof. Changing the key ID or protocol version invalidates it.
The surrounding evidence format remains `provider-financial-identities/v1`.

Configure `Rails.application.config.x.provider_identity_signing` with
`active_key_id`, `keys` (a map of key ID to strict Base64-encoded 32-byte secret),
and optional `legacy_v1_key_id`. The initializer supports these explicit
environment bindings:

| Environment variable | Configuration value |
| --- | --- |
| `PROVIDER_IDENTITY_SIGNING_KEY_ID` | ID used to sign new proofs |
| `PROVIDER_IDENTITY_SIGNING_KEYS` | JSON object mapping IDs to retained Base64 keys |
| `PROVIDER_IDENTITY_LEGACY_V1_KEY_ID` | Optional single historical key for unversioned proofs |

An environment value overrides that field's Rails configuration. Missing
configuration does not stop unrelated application boot, but proof capture fails
without an explicit active key. A verification-only process may retain keys
without an active signer. Unknown IDs, missing retained keys, malformed keys and
unsupported signature versions fail closed. Key IDs have at most 64 characters;
the keyring accepts at most 32 keys and a 16 KiB JSON configuration. Configuration
errors do not include key values. No keys are generated, written to credentials,
or installed by this implementation. Operators must provision independent random
keys through their existing secret-management process.

Rotate in this order:

1. Add the new key under a new ID to every process that can verify retained proof,
   retaining all old keys. Deploy this verification configuration first.
2. Change `active_key_id` on signing processes. New proofs use that ID; existing
   encrypted batches and signatures remain unchanged.
3. Keep each older verification key available for as long as any retained proof
   or restorable backup references it. Do not reuse an ID for different key bytes.
   Removing a key makes its proofs unverifiable; there is no automatic re-signing
   or evidence rewrite. The implementation does not automate a global key-usage
   or backup inventory, so retirement requires that operational check.

An old hexadecimal signature is accepted only when `legacy_v1_key_id` explicitly
selects its historical **derived 32-byte HMAC key** in the retained keyring. This
is the key previously derived using Rails' application key generator and the
purpose `provider-financial-identities/v1`; it is not the raw application secret.
Retain that exact derived key through a trusted operator process before rotating
or losing its original secret. Verification tries only the designated key and
the original typed encoding. It never guesses among retained keys or consults the
current application secret, and new capture never emits the old signature form.
The policy is disabled by default.

Transaction-scoped proof caching also pins the keyring configuration revision;
changing retained keys or legacy policy invalidates cached verification. Payload
encryption remains a separate requirement: retain the Active Record decryption
keys needed by live data and backups as well as these signing keys. Raw proof
payloads, financial snapshots and signing secrets must not enter ordinary logs.
Rotation and explicit legacy-policy tests are written but have not run here.

This retention protocol covers the permanent financial attestation only.
`MigrationCopier` still verifies copied account archives with the unchanged
application-derived key for `provider-migration-checksum-v1`. Re-reading or
reverifying those archives after application-secret rotation requires a separate
archive-key retention or migration protocol, which is not implemented here.
New financial signing keys do not make every migration proof rotation-ready.

The main copier rejects financial-bootstrap checkpoints, retained identity batches
and permanent mappings when restarting quiesced preparation or returning to legacy
operation. Checkpoint loss cannot reopen those paths. Its separate
[`verify_retained_quiesced_page` reader](provider-quiesced-copy.md) compares the
original copy without modifying that context or replacing evidence. Keep the
restart restriction until an explicit reconciliation protocol handles published
permanent mappings. Do not bypass it by deleting the checkpoint or old evidence. Complete lifecycle
fencing, native checkpoint translation, final-copy coordination and rollback remain
separate acceptance requirements.

The publisher tests cover exact UUID/value preservation without financial DML,
bounded restart, atomic failure, stale context, missing evidence, behind-cursor
insertions and identity/alias/type changes, and later permitted financial edits.
The resolution tests cover old Plaid IDs, archive-only aliases, later native
refresh/removal, stale proof, row contention, immutable capture and Entry
detachment. Separate tests cover the scoped cache and Ruby/SQL identity-state
equivalence. These tests require the additive schema and a working
Rails/PostgreSQL environment; they have not run in this workspace.
