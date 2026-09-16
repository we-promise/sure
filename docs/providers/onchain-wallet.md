# On-chain wallet account-data port

Status: staged snapshot normalization, immutable archive and quote contracts,
single-request explorer readers, migration routing projection and security
resolution are written. Tests are written but unrun. `native_ready?` remains false:
the shared runtime does not yet assemble these reader responses into a durable
wallet snapshot or supply the captured market prices. Existing wallets still use
the legacy path.

An on-chain connection groups the family's selected addresses and assets. Every
tracked `(chain, asset kind, wallet address, contract address)` is an external
account; it can link to an existing financial account. These are explicit user
selections. An explorer discovering a new token is never authorization to track it.
The existing `Onchain::Chains` registry still defines supported chains, token
identity and metadata. Bitcoin, EVM/Blockscout, optional Etherscan history, and
Solana RPC each have native readers under `OnchainWallet::Readers`.

Each reader call performs one HTTP request, with no internal sleep or retry.
Responses retain exact JSON decimals, reject redirects, and distinguish throttling,
authentication and malformed data. Native methods preserve the existing endpoints:
Bitcoin summary and transaction pages; Blockscout summary, token inventory, native
and ERC20 history pages; Etherscan native/token history within explicit fixed block
bounds; and Solana balance, one token program, one signature page or one transaction.
Solana token programs are separate requests. Empty transaction details remain
unknown. Configured self-hosted HTTP endpoints remain supported.

The normalization boundary consumes a sealed `SnapshotArchive` shared by every
selected asset at one wallet address. It retains asset quantities independently of
fiat valuation, source movement identities, calendar dates, inventory/history
truncation and raw request evidence. A canonical digest survives JSON object-key
reordering; asset/movement array order remains captured. Different snapshot digests
at the same address cannot be combined. All snapshot data stays in encrypted
storage. The current staging inputs are `ExternalAccount.sensitive_details`:

- `source_descriptor`: reviewed chain, asset kind, exact address/contract, symbol,
  name, decimals and stable ingestion namespace. The copier creates and verifies
  this projection without recurring reads of the complete legacy archive.
- `onchain_snapshot`: `SnapshotArchive.capture(...)` output, including version,
  captured observation time, completeness and evidence. Its wallet identity and
  captured time must match the selected sync context.
- `onchain_prices`: version, captured observation time, snapshot digest, external
  account ID, canonical ticker, target currency, current quote and dated historical
  quotes. Every quote contains its price/date, original price/currency and optional
  FX rate/date. Exact multiplication must reproduce the converted price. Same-unit
  prices must be unchanged and carry no fabricated FX.

Account inventory rows carry only the routing descriptor. Normalized pages refer
to the sealed snapshot digest and include their relevant asset/movement and price
evidence; they do not repeat the entire wallet blob for every selected asset. The
feeder must retain the original wallet artifact durably before publication. A
future artifact-reference collector can provide the same immutable input contract
without duplicating a staged wallet payload across external-account rows.

Current holdings use the latest captured quote on or before observation. Movements
require a quote for that exact calendar day; later prices cannot invent their cost
basis. Movement records retain signed asset quantities, the existing four-place
`-(quantity * price)` entry amount, `Transfer` activity label and family-locale name.
They are represented as trades because the financial model needs quantity and cost
basis even though the underlying event is a transfer. Canonical security aliases
reuse `CRYPTO:<symbol>` across MICs; the existing on-chain resolver binds a blank
price provider to `binance_public` and preserves another explicit provider.

The migration preserves `onchain_<legacy OnchainWalletAccount UUID>` as the holding
identity and adds `_<movement external ID>` for entries. The new ExternalAccount
UUID must never replace that namespace. ERC20 contracts retain normalized lowercase
identity; SPL mints preserve case. A copied fiat current balance remains separate
from the asset's archived exact quantity.

Activation still requires these pieces and acceptance checks:

1. A durable, rate-limited wallet feeder that stages each bounded reader response,
   resumes pagination, freezes the requested scope and seals a complete snapshot.
   Preserve native-coin and token inventory independently of history failures,
   every-chain partial success, mempool behavior, Solana signature deduplication,
   token-account aggregation and verified mint metadata. Missing Solana transaction
   details must mark history partial. EVM log-index identities and fallback
   identities must match the selected existing explorer.
2. An explicit market-data collection stage outside financial transactions: resolve
   selected asset securities, request missing history once per security/window,
   collect exact stored prices and dated FX, and capture them against the sealed
   snapshot. Persist both the original snapshot time and the selected family locale
   for crash resumption; the new job's wall clock must not relabel old observations.
3. A writer-owned disposition for legacy display-only excluded zero transactions.
   The old processor deletes these entries when a price arrives and creates trades.
   The native port quarantines unpriced movements and rejects representation
   conflicts; it must never destroy a protected/user-edited entry or replace its
   UUID implicitly. Implement reviewed identity-preserving promotion or keep those
   records pending explicit reconciliation. Idle wallets still require this repair
   and legacy Buy/Sell-to-Transfer relabeling when market data changes.
4. Explicit acceptance of valuation behavior. A missing price or incomplete asset
   inventory now preserves the prior financial value and reports partial data;
   the legacy processor often supplied zero. Confirmed complete asset absence is
   a known zero. Holdings absence/future-holding cleanup is disabled pending parity.
   Retaining available sold-out token movement evidence is another intended
   improvement over the old importer that emptied movements when an asset vanished.
5. Tracking/review/linking, address replacement, disconnection, optional Etherscan
   credentials and deployment endpoint configuration must move onto shared
   connection/external-account state. Preserve selected assets and exact source
   identity history when an address changes; a source-policy switch cannot infer
   the same wallet from an institution label or ticker.
6. Execute migration, financial parity, lost-response/restart, cutover and rollback
   tests in a provisioned Rails environment. No migration or live wallet cutover
   has run here.
