# Scalable Capital connector findings

Source: https://github.com/ScalableCapital/scalable-cli
Pinned source revision: d37db02f5dd0d88d8f161938614be2daec2a2741
Source inspected on 2026-10-19. No bank credentials or account responses belong in this folder.

## Login

First enable Scalable CLI on the Scalable web platform under Profile > Security > Agentic Investing (the official CLI README documents this prerequisite). The official CLI uses OAuth device authorization, not a redirect callback. Sure initiates an attempt and shows the official verification URL and user code. The owner signs in on Scalable's website and confirms any additional phone approval; Sure polls automatically until verified completion or expiry.

The backend creates a P-256 DPoP key. API requests use DPoP proofs bound to the access token and request URL. Access JWTs are checked against the issuer's signing keys, expected issuer/audience, time claims, person identity and DPoP binding when present. The public client identifier is not a client secret.

Refresh tokens can rotate. Sure serializes refresh and data requests per connection, validates the same person and DPoP key, and stores replacement credentials encrypted. A rejected refresh requires a new attended login. The actual session lifetime and renewal behavior for this account still require an attended live verification.

References: src/auth.rs, src/channel.rs, src/token_verifier.rs, src/dpop/mod.rs, src/session_refresh.rs.

The public OpenID discovery document was checked live without authentication on 2026-10-19. Its issuer, JWKS URI, device authorization/token endpoints and ES256 DPoP support match the pinned source. An attended device-code login, separate phone approval and automatic first brokerage import were also verified on that date. Refresh longevity and importing a nonempty securities portfolio remain unverified for this account.

## Read capabilities

- Broker portfolio discovery returns all broker portfolio IDs for the verified person; Sure must never choose an arbitrary first portfolio.
- BrokerOverview returns portfolio valuation, securities/crypto valuation and inventory timestamps.
- BrokerHoldings returns ISIN, name, type, filled/pending/blocked quantities, performance valuation/currency and quote metadata. fifoPrice is retained only as evidence until cost-basis semantics are verified.
- BrokerLimits returns cashBalance separately from credit, pending orders and cashAvailableToInvest. Buying power must never be imported as cash.
- BrokerTransactions is cursor-paginated and BrokerTransactionDetails includes fees, taxes and cash details. Settlement codes, signs and completeness need real response verification before mapping to Sure activity.
- Overnight savings are separate savingsAccount IDs with separate balances and history, not extra broker cash. Fixed-term products have separate capabilities too.

References: src/broker_shared.rs, src/broker_queries.rs, src/broker_projections.rs, src/overnight_queries.rs.

## Import boundaries

The first connector slice supports verified EUR broker cash and holdings snapshots without an outstanding margin loan. A nonzero or unverified loaned balance is rejected until its accounting contract is established. It uses the read time for the native account snapshot, keeps the bank valuation timestamp separately, reconciles the supplied valuation with holdings and cash before writing, and keeps prior data when responses are partial, stale or inconsistent. Reconnects reuse provider portfolio identities.

Settled EUR deposits and withdrawals are imported as native transactions after fully reading the available paginated history and verifying transaction details. Source deposits are positive and withdrawals negative; Sure's entry convention reverses those signs. A summary can say CONFIRMED while its detail is already settled, so the detail's pending flag and settlement history determine eligibility. Repeated imports use portfolio-scoped source identities. Incomplete, changed or unsupported history retains previous entries and reports a history-specific error while a valid current snapshot remains available.

Cash-only accounts can reconstruct their cash balance history from those settled movements. For accounts with observed securities holdings, charts start at the first positive holdings snapshot; older cash activity remains visible without implying earlier securities valuations or portfolio returns.

Trade activity, other cash transaction types, cost basis, total-return history, Overnight and fixed-term products require additional verified response contracts. The preview hides and rejects manual basis/security remapping and market-price replacement controls for connected Scalable holdings; incomplete local journal history cannot invent a basis for the imported position. Ordinary manual journal entries remain local bookkeeping and never call Scalable order APIs. A successful static test is not proof of account-level availability. No order, purchase, sale, withdrawal or transfer capability is implemented. CLI credentials themselves may still carry broader permissions; excluding trading code does not narrow backend permissions.

## Operation

Self-hosted administrators with preview features enabled can open Settings → Bank sync → Scalable Capital, or `/scalable_login`. Login attempts are tied to the initiating Sure session, encrypted, time-limited and cancelable. Passwords are entered only on Scalable’s website. Completed login queues the first snapshot; later syncs use the existing family scheduler and manual sync action. This connector adds no Docker service, public callback, browser runtime or inbound port.

The source reference is Apache-2.0; copied GraphQL selections and protocol-derived code are covered by the accompanying [source license](licenses/scalable-cli-Apache-2.0.txt).
