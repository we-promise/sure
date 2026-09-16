# Coinbase account data

The native `Provider::AccountData::Coinbase` package is implemented and remains
disabled by its readiness gate. Its tests have not run in the current workspace,
which has no available Ruby runtime. Existing Coinbase imports remain active.

The CDP API key and EC private key stay in encrypted connection credentials.
Bounded account and transaction readers keep the existing JWT path signing,
preserve exact decimal JSON and return one response plus its continuation.
Unauthorized or inaccessible histories fail visibly; they do not become empty
completed histories. Raw response evidence belongs to encrypted ingestion batches.

Each wallet keeps its upstream ID. `metadata.asset` stores the asset code, name,
type and exact quantity as a decimal string. Canonical account monetary columns
hold native fiat values. Holdings preserve `coinbase_<wallet_id>_<date>` identities,
exact crypto quantities, the existing eight-place unit-price rounding and
two-place fiat valuation. Observation dates use the captured sync time in the
family's timezone. Current inventory includes zero wallets, and native history
traversal exposes all continuation pages instead of the old 100-row total limit.

Only completed buys and sells enter the existing trade projection. Buy quantities
are positive and historical Coinbase entry amounts are negative; sells retain the
opposite signs. Transaction IDs, subtotal overrides, notes, labels and existing
trade preservation follow the legacy processor. Sends, receives, pending trades
and unsupported activity types remain outside that projection.

The shadow copier stores the original typed source row in encrypted chunks and
leaves financial account, entry and link UUIDs intact. Coinbase source
`current_balance` and `currency` remain recoverable as crypto units and code;
they are not copied into fiat balance columns. The queryable view prefers an
explicit `native_balance`. If that is absent, a linked account's balance and
currency are captured together and marked `linked_account_snapshot`. An unlinked
wallet without native valuation has a nil monetary balance, including when its
crypto quantity is zero. Copy verification rechecks the linked fallback snapshot.
These copied values require a fresh provider observation before native use.

Activation still requires:

- Executed runtime tests, shadow comparisons and the shared cutover checks.
- A reviewed identity map between `coinbase_txn_*` and deprecated
  `coinbase_buy_*` / `coinbase_sell_*` records. The legacy normalizer and readers
  are available for explicit migration replay; both endpoint families must not
  be imported independently as new trades.
- An explicit captured context for the old cached security-price and current
  holding-value fallbacks when native balance and spot prices are unavailable.
  The native adapter currently reports incomplete valuation in that case.
- Verification of security fallback identity and same-source holding behavior,
  including zero positions and the unchanged policy against deleting future
  holdings. A holding snapshot does not authorize unimplemented absence pruning.
