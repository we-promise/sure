# SimpleFIN classifier hint transfer

The quiesced row copier now retains the legacy liability-sign hint in the typed
account archive under `auxiliary_inputs.simplefin_liability_hint`. This closes the
native classifier's dependency on a volatile Rails cache entry. Implementation and
behavioral tests are written but unrun; SimpleFIN remains gated.

The capture preserves the original typed cache value, expiry and cache namespace,
along with capture time and explicit present/absent status. The document is covered
by the account archive's existing checksum and source mapping. Cache I/O runs
outside database row transactions while the exclusive legacy fence is held; the
archive and its account binding commit with the copied account. A retry of an
uncommitted account captures again, while verification of a committed archive does
not reread the cache or replace its original observation.

Absence means the cache returned no value at capture time. It does not establish
historical absence, upstream history completeness or a balance classification.
Expired values retain their exact expiry and are ignored by the classifier at its
fixed observation time. Invalid values require explicit disposition rather than
becoming a fresh or empty hint. Capture is bounded to 4 KiB.

[`RetainedHint`](../../app/models/provider/account_data/simplefin/retained_hint.rb)
reads the verified quiesced archive and checks the original financial-account
binding. [`Snapshot`](../../app/models/ingestion/balance_policies/simplefin/snapshot.rb)
uses that value only until native encrypted classifier state exists. A newer
native hint remains authoritative even after it expires; the old hint cannot be
revived. Applying a retained sticky result copies it into native encrypted state
without extending its expiry. Existing captured `legacy_cache` evidence remains
replay-compatible, but new native construction no longer reads that cache.

The frozen classifier snapshot retains the admitted value. Compact source
descriptors join the live runtime fingerprint, so changed mapping/copy provenance
invalidates requests without decrypting old history before every HTTP call.
Existing runtime account binding checks continue to guard relinking and currency
changes. The descriptor inventory is bounded to 1,000 external accounts.

New quiesced copies include the hint automatically, and preparation's retained
copy sweep verifies its shape and checksum. Existing quiesced archives without
this capture require explicit recopy where still eligible, or reconciliation;
they cannot substitute today's cache for missing copy-time evidence. Shadow copies
remain source-column comparisons and cannot seed this native retained input.

Tests cover real quiesced transfer, original typed value/expiry, explicit absence,
expiry, malformed input, cache eviction, original-account binding, native-state
precedence and actual registry/request construction with descriptor-only drift
checks. This input is part of the account archive; it adds no new preparation
checkpoint or input counter. Full classifier, history, lifecycle and cutover
acceptance remain in the [provider status](provider-implementation-status.md).
