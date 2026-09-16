# Retained source selection

Status: implementation, migration and behavioral tests written; runtime checks
remain unrun. This preserves selection history but does not activate native
providers, complete source handover, or implement Account retirement.

Different providers can observe one financial account. Each
[`Account::SourcePolicy`](../../app/models/account/source_policy.rb) revision must
continue identifying the selected source after an AccountProvider link is removed.
Otherwise an old batch's policy UUID cannot explain which connection supplied its
authority. This also matters when a historical-balance command references a
different policy for current balances.

## What a revision retains

The immutable `source_binding` has a version, capture kind, original account,
family and AccountProvider UUIDs, and integration key. For shared sources it also
retains the external-account and connection UUIDs. For legacy sources it retains
both account and parent-item type/UUID pairs. A copied dual link captures both.
These are scalar ownership references, with a 16 KiB database bound; credentials
and financial payloads are not copied into the policy.

[`Binding.capture!`](../../app/models/account/source_policy/binding.rb) captures
the financial identity, locks the selected link and allowlisted source owners,
then compares a fresh ownership inventory. It verifies exact migration mappings
for dual links. Database insertion guards independently validate the original
owner; ordinary updates cannot change the captured tuple, revision or creation
identity. An inactive revision cannot be reactivated. Selecting again creates a
new revision when required.

The policy's financial FK targets
[`Account::IngestionIdentity`](../../app/models/account/ingestion_identity.rb).
Its shared source references keep their original external account and connection.
A conditional composite FK keeps the live AccountProvider while the policy is
active or its binding is unknown. An inactive, fully captured revision can outlive
that link while preserving its original UUID. The link UUID cannot be reused or
its source identity replaced while retained revisions refer to it.

A legacy link may gain its exact copied shared counterpart. This is a one-way
enrichment: the old binding remains unchanged. Since the copier attaches the link
before saving its mapping, a deferred database check verifies the final mapping,
control, connection and captured legacy item together at commit. A migration
state alone does not authorize enrichment.

## Existing rows and transparent transfer

The migration creates missing financial identities only from existing FK-validated
policy/link/Account ownership, then transfers the policy FK transactionally.
Existing policy bindings remain `{}`. Today's link is insufficient evidence of
what an old selection originally meant, so the migration does not invent history.
Compatibility SQL insertion may still leave an unknown binding only with a live,
non-deleting Account, matching live identity and matching link. Normal Rails
selection always captures a complete binding.

An unknown revision remains immutable and keeps its live link, including after
deactivation. Reselecting the same provider creates a new captured revision but
does not resolve that older unknown. Detaching it requires an explicit historical
disposition. No backfill, migration or live data transfer has been executed here.

## Discovery and unlinking

[`Ingestion::SourceOwners`](../../app/models/ingestion/source_owners.rb) is shared
by selection and provisional lifecycle discovery. The old
`Account::Destruction::SourceOwners` name remains a compatibility alias. Retained
policy snapshots are checked against persisted revisions and contribute their
original owners without claiming that a historical link still exists.

CoinStats, Onchain and direct SimpleFIN unlinking can remove legacy tracking rows.
A captured policy can still identify the original parent item after that removal;
the proof explicitly marks the account row as missing. It never substitutes for
a missing current link. A changed parent, missing parent item, conflicting origin
or incomplete dual mapping still refuses discovery. Unknown policies require
disposition instead of being interpreted through current links.

For legacy-owned links, `Account::Unlink` deactivates fully captured selections
that have no retained ingestion batches, and preserves the revisions while
removing links. It still refuses retained primary or secondary historical-policy
references, and requires historical-command routing coverage before detachment.
Failed tracking cleanup rolls back policy deactivation as well as link/holding
changes. The [native account unlink path](provider-native-account-unlink.md)
retains source rows and all evidence, so its captured policies may be deactivated
even when batches reference them. Document publication and connection deletion
remain separate operations. All of this coverage is written but unrun.

## Remaining lifecycle work

Account destruction and scheduling refuse identities with source observations or
policy history before destructive callbacks/enqueue. Normal Account and link
associations no longer cascade policy deletion. This change does not install a
blanket SQL prohibition on explicit policy deletion; complete evidence retirement
and full-family purge still require their own admitted disposition.

The future retirement command must retain Sync history, apply statement/import
dispositions, check permissions and the complete financial/source graph, and
retire the identity atomically with live Account removal. Runtime migration,
concurrency and all-provider parity checks remain required. See
[implementation status](provider-implementation-status.md),
[source discovery](provider-account-source-inventory.md) and
[multiple-source ingestion](multi-source-ingestion.md).
