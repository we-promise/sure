# Enable Banking authorization inventory publication

Status: authored with focused behavioral tests; Ruby tests have not run in this
workspace. Native readiness remains false. This is an account-discovery change,
not a native consent renewal or activation workflow.

Enable Banking's shared connection represents application credentials. Each
`ProviderAuthorization` represents a separate institution consent, and
`ProviderAuthorizationAccount` records its account membership. Discovery now
publishes the exact membership alongside each successfully normalized account,
before later requests use that membership in their captured source binding.

[`AuthorizationInventory`](../../app/models/provider/account_data/enable_banking/authorization_inventory.rb)
runs inside the ordinary Syncer publication transaction after the existing
request grant and request-input verification. It checks the original accounts
cursor fingerprint and ordered consent position, then reconstructs each output
using the same pure normalizer and the captured session UID, detail response, and
supplemental account data. A record cannot borrow another consent from the same
connection or point at an unrelated account.

Publication preserves existing memberships and adds only missing active
memberships for the selected consent. An existing account requires that exact
active membership or its previously captured native consent metadata. A revoked
membership or an account owned by a different consent is refused, including a
collision of stable identifiers, retained aliases, or API UIDs across institution
consents. Different accounts within one page cannot share those identifiers
either. Original copied identity aliases participate in this check. Copied
accounts with the exact existing active membership do not need a preexisting
native `authorization_id` metadata field.

The transaction verifies the exact permitted ExternalAccount attribute changes,
unchanged other source rows, unchanged financial-link and scalar account context,
and the exact membership additions. It then constructs a replacement registry
factory and request grant under the same locks. Connection credentials,
authorization revisions, runtime configuration, unrelated account inputs, and
linked-account inventory must remain unchanged. The replacement preserves the
original `observed_at`; its new wall-clock fingerprint may differ. The original
factory grant and captured batch are never rewritten.

This explicit replacement matters because authorization memberships and retained
account aliases are request inputs. Merely inserting a membership would make the
old factory stale on the next consent page. The replacement becomes available to
the Syncer only after its publication transaction succeeds; construction performs
no HTTP. A failed publication rolls back account and membership writes together,
leaving the captured response available for retry. Same-Sync recovery skips an
already applied page and constructs a fresh factory from its committed state,
without repeating its HTTP or rewriting its original proof.

Partial inventory is additive. Successfully captured account prefixes may be
published while an unavailable consent remains incomplete. An empty failed page
adds nothing. Absence does not revoke a membership, close an account, change a
consent's status, or advance inventory coverage. Subsequent complete and partial
pages retain the original consent order and failure state.

Limits are 2,000 outputs per consent page, 10,000 external accounts per connection,
32 MiB for the encoded page, and 32 MiB for the captured source documents and
variable text fields. Source hydration follows an exact ID/row-version tuple
preflight; decoded account attributes also have a 32 MiB limit. The existing
request-grant limits of 10,000 authorizations and 20,000 memberships still apply.
Financial context reads use scalar columns and are bounded by the external
account inventory. As elsewhere in the shared encryption layer, checking decoded
size does not impose a strict allocation limit on decompression itself.

The [focused tests](../../test/models/provider/account_data/enable_banking/authorization_inventory_test.rb)
use registry-built adapters and real Syncer publication with fake transport. They
cover multiple consents, explicit linking followed by financial reads, missing
membership repair, copied membership compatibility, cross-family and same-family
consent confusion, revoked membership refusal, partial inventories in both consent
orders, transaction rollback, delayed same-Sync replay, unchanged original batch
bytes, and narrowed BOOK-to-PDNG history that preserves prior checkpoint coverage.

Native consent renewal, grant revocation/status transitions, and activation remain
separate gates. This change neither rotates consent credentials nor authorizes
automatic source reassignment when one consent becomes unavailable.
