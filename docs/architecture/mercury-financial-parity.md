# Mercury financial publication parity

As of the current working tree, the native adapter and shared writer preserve the
following Mercury conventions. The regression tests are authored but unrun in
this environment. Production `native_ready?` remains false; no migration,
cutover, live request or financial-data change was executed.

## Balances and transaction amounts

The [legacy account processor](../../app/models/mercury_account/processor.rb)
and the [native adapter](../../app/models/provider/account_data/mercury.rb)
already agree on balance signs. The native adapter declares the policy; the
[ledger writer](../../app/models/ingestion/ledger_writer.rb) applies it using the
linked financial account's type, rather than the provider's account label.

| Financial account type | Stored balance and cash balance |
| --- | --- |
| Depository | Mercury `currentBalance` |
| CreditCard, Loan | Negative of Mercury `currentBalance` |
| OtherLiability | Mercury `currentBalance` |

Positive, negative and zero values follow the same rule. Currency remains USD.
Transaction amounts are negated independently of account type: a Mercury
outflow becomes a positive expense. Native monetary parsing requires exact
decimals; the separate legacy-cache normalization method explicitly reproduces
the old Float-to-string conversion where a retained cache already lost precision.

## Stable identities and transaction status

Both processors use `mercury_<remote transaction id>`. A pending transaction that
posts under that ID updates the original Entry and Transaction UUIDs. Signed
bootstrap mappings continue to identify their original proof batch even when a
new provider observation becomes the SourceRecord's latest batch.

Mercury now declares the `pending_to_posted` transaction status policy, and each
normalized transaction captures that declaration in its metadata. After source
selection, exact identity resolution and financial row locks, the writer checks
the declaration. If a mapped SourceRecord is already booked and the incoming
record is pending, it repeats the locked mapping/proof verification and leaves
the financial rows and booked SourceRecord unchanged. The pending response stays
in its immutable ingestion batch. It does not replace the booked publication
pointer or rewrite the permanent identity proof.

The same observation rule applies while another linked provider owns transaction
publication. A secondary Mercury feed cannot erase its booked baseline and then
regress the original posting when authority returns. Mapped secondary evidence
receives the same locked proof check. Unmapped booked observations remain
observations only: stale pending cannot create a posting from them; a fresh
booked response under Mercury authority is still required.

This preserves the legacy importer's refusal to regress a booked ID to pending.
It does not freeze all future observations: pending updates before posting and
later posted corrections can still pass through the existing protected-field
rules. The policy is opt-in; other adapters retain their existing behavior.
Previously captured Mercury transaction pages without the declaration refuse
publication and need explicit reconciliation or a fresh request. No existing
capture is rewritten to add the policy.

The normalizer excludes only `status == "failed"`, matching the legacy processor.
A failed row remains raw batch evidence with an exclusion warning. It creates no
new financial posting and does not withdraw an earlier posting or clear an
earlier pending flag. Mercury pages remain deltas without an absence or removal
claim. Other nonpending statuses retain their existing interpretation; this
change does not invent cancellation or reversal semantics.

User-modified entries retain their financial values; the existing importer may
clear their pending flag when the provider posts. Excluded, import-locked and
reconciled entries remain protected, including their existing pending flag. The
SourceRecord can nevertheless record that the provider posted, preventing a
later stale pending response from regressing that observation. Invalid,
withdrawn or missing signed mappings and changed source selections still refuse
publication before the stale-pending no-write return.

## Evidence and remaining work

The new [financial parity suite](../../test/models/provider/account_data/mercury/financial_parity_test.rb)
runs the real legacy processors, quiesced copier, signed identity bootstrap,
native normalizer, captured batch and ledger writer against isolated test data.
It covers balance signs across four account types, pending/booked replay,
unchanged financial UUIDs and proof bytes, authority switches, protected entries,
failed rows and identity/policy refusal. Migration proof and financial publication use production
code, with local transport responses and a test-only readiness override; no
network request is made. Existing
[normalizer tests](../../test/models/provider/account_data/mercury_test.rb)
cover exact decimals, transaction signs, family-zone dates and other status
values.

These tests still need execution against the migrated PostgreSQL schema. This
slice does not establish full provider acceptance or close the separate
[lifecycle limits](mercury-lifecycle-admission.md),
[cutover history constraints](mercury-cutover-history.md), or legacy pending
cleanup's wider account/provider mutation concerns. Different provider IDs and
different sources are not reconciled by amount/name matching here.
