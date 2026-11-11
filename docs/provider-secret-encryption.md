# Dynamic provider secret encryption

Dynamic provider fields registered with `secret: true` are masked in the UI and
encrypted before database persistence. Ordinary settings are unchanged. Declared
encrypted settings continue to use their existing accessors. ENV-only values are
not copied to the database. Legacy plaintext remains readable without writes.

The versioned YAML envelope uses the existing settings encryptor, derived from
`SECRET_KEY_BASE` with the `setting_encryption` salt. This is separate from Item
Active Record encryption and does not require its explicit encryption keys.
Web, workers and tasks must retain the same stable settings key. Unauthenticated,
malformed or unsupported envelopes raise `Setting::SecretError`; they do not fall
back to plaintext or ENV. Preserve the key with appropriately protected backups.

## Explicit conversion (operator approval required)

This task is not run automatically during deployment or database setup:

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
Credential rotation is a separate operator decision. Do not publish a security
branch or PR before coordinating privately with the maintainer.
