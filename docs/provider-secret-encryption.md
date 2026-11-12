# Dynamic provider secret encryption

Dynamic provider fields registered with `secret: true` are masked in the UI and
encrypted before database persistence. Ordinary settings are unchanged. Declared
encrypted settings continue to use their existing accessors. ENV-only values are
not copied to the database. Legacy plaintext remains readable without writes.
Writes load only the owning adapter's field metadata; an unrelated adapter's
load failure does not block them. The backfill requires complete secret metadata
and stops if an adapter cannot be loaded.

The versioned YAML envelope uses the existing settings encryptor, derived from
`SECRET_KEY_BASE` with the `setting_encryption` salt. This is separate from Item
Active Record encryption and does not require its explicit encryption keys.
Web, workers and tasks must retain the same stable settings key. Unauthenticated,
malformed or unsupported envelopes raise `Setting::SecretError`; they do not fall
back to plaintext or ENV. Preserve the key with appropriately protected backups.

Use a unique, private `SECRET_KEY_BASE`. A public example/default key provides no
protection against an attacker who can read the database. This settings encryptor
does not support key rotation or Active Record's previous encryption schemes;
rotating only the Active Record keys does not rotate these settings.

If a saved Plaid credential is unreadable, that region is unavailable for new
connections; manual accounts and other providers remain available. Provider
settings show the error and allow replacement. Saving other fields with the
unreadable secret left blank preserves its envelope for recovery with the original
key. To discard it deliberately, select the delete checkbox and save; this permits
ENV fallback.

## Explicit conversion (operator approval required)

This task is not run automatically during deployment or database setup.
It is separate from `security:backfill_encryption`, which covers Active Record
encrypted model columns rather than dynamic settings.

```sh
bin/rails provider_secrets:backfill                 # counts only
APPLY=true bin/rails provider_secrets:backfill      # convert stored rows
```

Before conversion, preserve the existing key and a protected recovery copy.
Schedule a maintenance window with old web/worker processes stopped, and deploy
all new readers before backfilling. Old releases cannot read envelopes and may
write plaintext again; mixed-version operation is not supported.

The task processes only stored registered dynamic secret rows, locking and
reloading each row within its own transaction. It validates existing envelopes,
skips empty values and clears settings caches on conversion. Task output contains
only counts; failures log the row ID, setting name and exception class, never the
stored value or exception message. A failure produces a nonzero task exit status;
successful rows remain converted and reruns safely resume. Investigate failed
rows without logging their contents. Do not automatically decrypt rows back to
plaintext for a downgrade; restoring the previous release is not a transparent
rollback.

This protects current logical storage, not old backups, WAL or database pages.
Credential rotation is a separate operator decision.
