# Akahu native lifecycle

Status: implementation and behavioral tests are authored, not executed acceptance.
Akahu still inherits `native_ready? == false`. No live source has been migrated,
retired or disconnected by this work.

## Shared configuration and setup

The [adapter](../../app/models/provider/account_data/akahu.rb) declares both
`app_token` and `user_token` for the shared static credential editor. Blank fields
retain the existing value. Replacement uses the shared credential lock, original
signed form and idle-work checks; original legacy credentials and encrypted
migration archives remain unchanged.

Akahu declares Depository, CreditCard, Loan and Investment setup. A pure
`account_setup_defaults` hook supplies subtype suggestions and Investment cash
balance zero from frozen, nonsecret source context. The shared command validates
these defaults and binds them into the signed selection. Defaults apply only to
new accounts; the user's explicit balance retains its sign. Linking an existing
account preserves its financial fields and existing source policies.

A retained unlinked source is eligible only with its verified original nil
financial binding and nil/empty transaction cache. Linking does not rewrite that
archive. The account, link, selected policies, retained observations and durable
Sync receipt use the shared atomic command and retry path.

## Compatibility routes and retirement

Akahu's old edit/setup URLs now opt into shared management routing after native
cutover, while the original rows still exist. Stale update, disconnect and setup
submissions return the shared destination; their old parameters do not become a
new command. Live manual sync continues through `AkahuItem::SyncRequest` and its
original ownership checks. After retirement, saved member URLs require the exact
authenticated retired-owner proof. Readiness, family and administrator checks
apply to both paths.

The reviewed retirement disposition permits only Akahu's original account/item
rows and verified old logo attachment to be removed without callbacks. It uses
the existing exclusive legacy permit, complete inventory and idle-work checks,
original archive/identity verification and durable receipt. AccountProvider and
financial UUIDs, original Sync ancestry, source evidence, encrypted archives and
the shared logo blob/attachment remain. Unexpected source rows, cache/token drift,
extra attachments or changed proof refuse retirement. This does not drop legacy
tables/classes or revoke upstream credentials.

## Acceptance still required

The [financial parity suite](../../test/models/provider/account_data/akahu/financial_parity_test.rb)
uses actual legacy import, copy, preparation and cutover followed by the shared
factory-built Syncer. It covers stable/protected Entry identity, pending settlement,
liability signs, Investment cash, account currency, merchant/notes/metadata and
configured or unbounded first history windows. The
[pending parity suite](../../test/models/provider/account_data/akahu/pending_parity_test.rb)
adds complete paginated/empty inventories, failed-tail continuation, malformed
responses, idless native occurrences, user protection and transfer/split retention.
Currency-transition cases keep old explicit-currency postings and original
archives while publishing a new complete account balance in its reported unit;
new transactions without an explicit currency use that new source unit. This
does not convert or relabel existing historical amounts. The
[idless identity suite](../../test/models/provider/account_data/akahu/pending_identity_test.rb)
also refuses a currency change that would reuse a synthetic hash for a different
monetary unit, using signed original or mapped financial evidence. Explicitly
retained original units remain eligible. The
[retirement suite](../../test/models/provider/account_data/akahu/retirement_test.rb)
and [saved-route suite](../../test/controllers/akahu_native_routing_test.rb) cover
physical row removal, retained proof, replay, permissions and native routing.

These tests require execution, alongside shared-runtime regression checks.
Ambiguous idless occurrence identity, executable currency-transition checks and
complete pending/history acceptance remain open in [cutover history](akahu-cutover-history.md). Declaring
lifecycle capabilities is not permission to enable native readiness.
