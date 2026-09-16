# Durable provider migration preparation

Status: implementation and behavioral tests are written, with no Rails/PostgreSQL
execution or live migration in this workspace. This coordinates retained copies,
transaction/activity identity evidence and explicitly integrated provider inputs.
It does not complete provider migration acceptance or activate a connection. The
separate cutover command consumes the original completed preparation and repeats
its verification inside the ownership handoff. It has [Up](provider-up-cutover.md)
and [Mercury](provider-mercury-cutover.md) history contracts; each remains subject
to its adapter's native-readiness gate.

## One resumable sequence

`Provider::AccountData::MigrationPreparation` accepts an exact provider key, legacy
item UUID, authorized Family and page size from 1 to 500. The caller must authorize
the operation before passing that family. There is no caller-supplied cursor,
completion flag or account subset.

```ruby
preparation = Provider::AccountData::MigrationPreparation.new(
  provider_key: provider_key,
  legacy_item_id: legacy_item_id,
  family: authorized_family,
  page_size: 100
)
result = preparation.run
```

Fresh instances with the same arguments resume committed progress. Each call does
one bounded copy/inventory page, one financial-identity page, a provider-input
operation, an explicit disposition, or a phase transition. The phases are:

1. `copy`: create or finish the original quiesced copy. Existing verified quiesced
   copies are retained, including copies with existing identity evidence.
2. `inventory`: enumerate every retained source account from the beginning. Store
   its exact mapping UUID, source checksum, external-account UUID, link revision,
   financial account context and linked/unlinked disposition.
3. `capture_auxiliary` (20 logo providers): retain and verify the connection's logo attachment
   archive before financial identity publication. This runs once per connection,
   including a connection with no source accounts or no logo.
4. `identities`: publish and verify the existing financial UUIDs for each linked
   mapping through `Ingestion::IdentityBootstrap`. An unlinked source has no
   financial bootstrap; its explicit disposition is checked without inventing a
   financial account or checkpoint.
5. `install_inputs` (Binance): retain an explicit input disposition for every
   source account. A supported linked combined account installs its signed history
   seed after identity verification; unlinked and unsupported account topologies
   retain unresolved dispositions instead of fabricated seed inputs.
6. `verify_copy`: enumerate the retained copy again from the beginning. Compare
   each exact account receipt and the ordered inventory digest/count against the
   original inventory. Same-count source replacement or a newly linked account
   invalidates the comparison.
7. `verify_identities`: explicitly restart and complete each linked account's
   identity verification. Calling an already-verified publisher alone is not a
   fresh full sweep of all retained financial proof.
8. `verify_inputs` (20 logo providers, plus Binance history): independently reverify the exact original
   auxiliary archive or history seed after the fresh copy/identity sweeps. Read-only
   verification cannot replace missing child proof with a new installation.
9. `journal_cached_changes` (Plaid): capture and verify the complete ordered
   [cached-observation journal](plaid-cached-change-journal.md), including blockers
   and unlinked accounts. This separate receipt does not count as an installed
   input or accepted cursor. Parent reverification repeats the original journal's
   verification, preserving its signed pages and checkpoint.
10. `awaiting_acceptance`: report the completed sweeps and unresolved input
   dispositions, retaining `requires_cutover_reverification: true`. Native
   execution stays disabled.

`verified_identities_count` counts linked account mappings whose final sweep
finished, not financial rows. Each mapping separately retains its checkpoint,
batch and captured/verified Entry counts. Transaction and activity source policies
must already be selected wherever required by identity publication. The coordinator
does not choose among overlapping providers or manufacture a source authority.

## Provider inputs have explicit scope and incomplete acceptance

The original row copy also supplies directly derived runtime values. Trading 212
and Trade Republic retain their item currency in `ProviderConnection#settings`,
where the native factories read it before considering family reporting currency.
SnapTrade retains `oauth_token_expires_at` as UTC ISO8601 with nine fractional
digits in encrypted connection credentials, alongside `oauth_scope` and
`oauth_token_type`, so refresh decisions and subsequent rotations preserve token
metadata. A null expiry remains null. The original typed timestamp stays in its
archive and `legacy_state` checkpoint; scope/type also remain in copied settings.
No legacy sync timestamp is promoted to native coverage by these projections.

Both ordinary and retained copy verification compare these values. A prior copy
missing them fails retained verification without a silent upgrade or token
exchange. An eligible unused copy can be explicitly recopied; an already verified
quiesced copy needs an explicit restart. Existing preparation/identity/auxiliary
evidence still prevents restart and requires reconciliation of the original copy.
These row-derived values belong to copy verification, not the separately counted
input installations below. Their behavioral tests remain unrun.

The versioned input contract names every current migration manifest. Adding a new
provider without updating that catalog is an error. This prevents an omitted
integration from silently appearing prepared, but the catalog is not a complete
inventory of every provider's cutover requirements.

`input_integration` is `partial` for all 20 declared logo providers and
`not_integrated` for Onchain wallets, Trade Republic and Wise.
`installed_inputs_count`, `verified_inputs_count` and
`unresolved_inputs_count` describe only these integrated inputs. None of these
values asserts complete upstream history or native readiness. Zero counts for a
provider without integration mean unavailable work, not successful verification.

- Each logo provider has one connection-scoped input. Its retained receipt includes the original
  checkpoint, copy context, attachment identity and monotone chunk progress. The
  final sweep rereads bounded source/archive bytes, including the explicit
  no-attachment case. Its verification cursor belongs to the parent's current
  verification run; it does not mutate the original child receipt. See
  [shared logo transfer](provider-logo-transfer.md). IBKR retains its original
  class, stream, formats, key prefix and signer salt; the other 19 use the shared
  logo format. No existing receipt is silently reinterpreted.
- Binance additionally has one input disposition per retained source account, so
  its expected input count is one plus the retained account count. The final sweep
  verifies its logo before account inputs. An installed
  disposition records the original checkpoint UUID, batch UUID and signed receipt
  digest. Final verification rechecks the history plan and permanent financial
  identity proofs against that original seed. A fresh identity sweep may advance
  its checkpoint revision and verification timestamp; it cannot change the
  captured financial context. Unlinked and unsupported topology dispositions are
  checked again and remain unresolved. See [Binance history
  bootstrap](binance-history-bootstrap.md).
- Plaid also requires the separate `observation_journals` contract. The journal
  records cache observations and current authority after the other final sweeps;
  it does not change installed/verified input counts. Its phase can finish with
  unresolved observations and missing-history evidence. Older Plaid preparation
  contracts require explicit reconciliation before resuming this new sequence.

IBKR logo verification does not establish Flex-history completeness. Binance seed
verification does not establish upstream coverage or install an executable cursor.
Pending continuity, holdings/history handoff and other provider inputs remain
separate acceptance requirements.

## Persistence and crash recovery

The additive migration adds encrypted `preparation_state` documents to
`ProviderMigrationControl` and `ProviderMigrationMapping`. Connection progress is
bounded independently of the number of accounts; per-account receipts live on
their existing mappings. The coordinator never stores its progress in the copier's
watermark/audit or masquerades as an executable native checkpoint.

One outer exclusive legacy session fence covers each primitive call and its
subsequent progress commit. Admission occurs before any database transaction.
Child primitives commit independently; the coordinator does not hold their row
locks across the entire sequence or reuse the copier lease. Family, copy run,
manifest, source inventory, page size and connection configuration are pinned.
Each identity or account-input page rechecks its exact retained source/link before
invoking its child. Progress commits compare the previously read
connection/mapping state.

A child may commit before its parent receipt does. On retry the child resumes its
own checkpoint, and the coordinator counts completion only when its receipt
commits. This also preserves a Binance seed committed before its parent receipt.
A failed receipt after `restart_verification!` can repeat that restart;
the explicit per-mapping subphase prevents restarting every successful page. Old
financial proof and copied source archives are retained throughout.
Once a child checkpoint appears in a committed receipt, later pages must resume
that exact UUID. Empty accounts cannot silently replace a lost checkpoint merely
because there are no identity batches to reveal the loss. Committed child progress
may be ahead of its parent receipt after interruption, but cannot regress behind it.

Errors leave the control quiescing and retain committed progress. Busy admissions
retain their specific retryable exception; child validation errors retain their
original exception class. Diagnostics contain only scope IDs and error classes.
Neither failure cleanup nor a missing identity checkpoint reopens legacy writes.
The copier also refuses restart/resumption while any preparation progress remains,
including the interval before the first financial identity batch and sources with
no financial entries. Losing connection progress while account receipts survive
requires explicit recovery of that progress, not a new run over unknown receipts.
Connection-scoped logo proof requires the same recovery even when there
are zero accounts.

`restart_verification!` repeats the final copy, identity and integrated-input sweeps,
retaining the original inventory, preparation run ID, copy run, signed identity
batches and provider-input installations. It starts a new verification run ID so
old account or auxiliary receipts cannot count as newly verified. An ordinary
terminal `run` returns the existing historical report; it is not a fresh acceptance
check.

Preparation and per-account receipt formats are now `v2`. Earlier `v1` documents
are rejected, including terminal documents; they cannot be silently promoted past
new input phases. Recover their original progress and evidence explicitly before
resuming. The coordinator supplies no automatic destructive reset or receipt
upgrade.

The added logo scopes also change the exact v2 input contract for the 19 non-IBKR
providers. Existing v2 progress lacking that scope is rejected, including terminal
progress; recover/reconcile it explicitly. Existing IBKR v2 contracts remain
unchanged. A logo receipt alone never accepts account history, pending continuity
or provider credentials.

## Remaining acceptance work

The session fence still covers only declared writers. Separate account pages are
not a single database snapshot; account changes after a page is checked remain
possible through uncovered operations. Before activation, complete and deploy the
legacy/lifecycle boundaries, drain old workers and perform the coordinated final
reverification. The preparation report is not transferable activation authority.

The next acceptance stages must also reconcile native cursors and history windows,
cached changes not yet processed by legacy workers, historical balances, holding
identities and the remaining provider-specific auxiliary data. Provider credential
handover, source selection, pending continuity, atomic activation, rollback and
retirement remain required. Neither PDF publication nor import cleanup rules are
enabled by this preparation sequence.

Page limits bound account/identity counts, not total time or materialization memory.
The existing retained-reader and identity-publisher byte limits still apply; initial
legacy item admission can materialize a large row before those checks. Durable
progress documents have a 1 MiB decoded write bound and a separate stored read
preflight. These are not general limits on the size of financial history.

See [copy preparation](provider-quiesced-copy.md),
[identity evidence](financial-identity-evidence.md), the
[provider matrix](bank-data-provider-migration-matrix.md) and
[implementation status](provider-implementation-status.md) for the other gates.

## Verification

`test/models/provider/account_data/migration_preparation_test.rb` covers fresh
workers, initial and existing copies, Plaid aliases, linked/unlinked inventory,
original UUID/value preservation, encrypted receipts, phase restarts, source/link
drift, real-session contention and child-commit/parent-receipt crash boundaries.
It also checks that retained signing-key removal blocks a fresh identity sweep.
`migration_preparation_inputs_test.rb` covers Binance installation, original seed
preservation across final sweeps and parent-receipt interruptions, lost proof,
explicit unresolved dispositions, old receipt rejection and policy drift.
`migration_preparation_input_admission_test.rb` checks that installation and final
input verification cannot skip the required original or fresh identity receipts.
`migration_preparation_ibkr_test.rb` covers connection-scoped preparation, absent
accounts/attachments, chunk resumption, child/parent commit interruptions, final
sweep restarts and lost or changed proof. IBKR's retained auxiliary tests also
cover exact copy/attachment binding and bounded read-only byte verification.
`migration_preparation_logo_test.rb` and `auxiliary_copier_test.rb` add non-IBKR
storage/parent interruption, final sweep retry, source/target and family checks,
the full 20-provider attachment inventory and explicit prior-contract rejection.
These tests have not run. Execute the coordinator and provider-input tests with
the copier, retained-reader, identity publisher and legacy-fence suites against
the additive schema before use.
