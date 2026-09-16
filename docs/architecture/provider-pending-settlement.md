# Native pending settlement

Akahu, Lunch Flow and Redbark now opt stable-ID posted transactions into a bounded
native settlement policy. Their legacy entry processors all use the shared exact
match rule: same amount and currency, with a pending date on or before the posted
date and no more than eight days earlier. There is no merchant-name condition in
that forward rule. Synthetic posted identities do not opt in for Akahu or Lunch
Flow.

The native writer requires the currently selected source and one unambiguous
pending posting for the same ExternalAccount and financial Account. Both the
SourceRecord and the provider's own Transaction pending flag must still be
current. A current posting EntrySource and valid native or signed bootstrap
identity proof are required. A bare Entry, another provider, another external
account, or an evidence-only mapping cannot authorize a transition. Candidate
reads return at most two rows; multiple candidates refuse publication.

The writer locks and rechecks the candidate before invoking the existing native
pending-identity transition. The Entry UUID and original pending date survive.
The posted SourceRecord gets its posting mapping; the old SourceRecord becomes
withdrawn and retains its mapping, and Transaction metadata keeps the retired
external ID. Replaying either identity therefore cannot create another entry or
restore the old pending observation.

Akahu's [signed idless pending binding](akahu-cutover-history.md) now also retains
an unambiguous unsuffixed original through migration and late replay. The native
identity lookup includes withdrawn observations so a retired alias cannot acquire
a newly allocated financial suffix. Explicit withdrawals, repeated migrated input
occurrences and ambiguous persisted suffix families still require disposition.

Financial protection follows the existing explicit-transition contract. User
fields and compatible locks survive; excluded, import-locked and reconciled rows
keep their financial values. Their pending display flag may remain protected,
while identity evidence still advances. A locked metadata document that prevents
recording the retired alias refuses the whole transaction. Matching uses current
Entry economics; it does not infer a match through a user-changed amount or
currency, nor authorize approximate tip matching.

[Lunch Flow's posted-first rule](provider-lunchflow-late-pending.md) separately
retains late ID-less pending observations as evidence without editing the posted
entry. Its live-evidence withdrawal limitation remains unchanged.

## Withdrawal preserves surrounding financial records

The shared `TransactionWithdrawals` command now retains a posting when deleting
it would remove or detach related financial decisions: transfer legs and fees,
rejected transfers, split relationships, matched goal pledges, recurring payment
allocations, recurring match rejections or price history, and receipt attachments.
It also refuses to delete a Transaction shared by another Entry. This applies to
both exact API tombstones and absence from a complete pending inventory.

The source observation still becomes withdrawn. A retained posting keeps its
economic values and relationships; only the source's pending flag is cleared when
its metadata is unlocked. Entry and Transaction field locks both participate in
the existing protection check. A locked metadata document remains unchanged.
An unprotected, unrelated cancelled hold can still be removed while its original
Entry UUID and signed migration proof remain in source evidence.

The [exact-removal regressions](../../test/models/ingestion/mapped_entry_publication_test.rb)
and [Akahu migration-to-native pending suite](../../test/models/provider/account_data/akahu/pending_parity_test.rb)
cover these boundaries, complete multi-page inventories, failed/invalid responses
and same-Sync continuation. They are authored but unrun.

Behavioral tests use the three production normalizers and LedgerWriter for both
same-page and later-page settlement, replay, protected fields, ambiguity,
unmatched economics, source isolation and malformed policies. Tests are authored
but unrun because Ruby/Bundler are unavailable. Separate real quiesced-copy and
signed-bootstrap tests cover each provider's retained pending UUID, locked fields,
original proof ciphertext and late pending replay. No readiness flags, migrations
or activation changed.
