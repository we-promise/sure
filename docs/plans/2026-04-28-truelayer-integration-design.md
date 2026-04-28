# TrueLayer Integration Design

## Overview

TrueLayer is a UK/EU Open Banking provider supporting 2,500+ banks via PSD2. This integration adds TrueLayer as a bank sync provider, following the GoCardless OAuth2 token pattern with per-family credentials (each family registers their own TrueLayer developer account).

**Key decisions:**
- Per-family credentials (`client_id` + `client_secret`) — Enable Banking style
- TrueLayer-hosted bank picker — no in-app bank search to build
- Scheduled sync only — no webhooks (per-family client_id makes webhook setup impractical for self-hosted)
- GoCardless-style reauth flow for expired tokens

---

## Data Model

### `truelayer_items` table

One row per family bank connection.

| Column | Type | Notes |
|--------|------|-------|
| `family_id` | uuid | FK |
| `name` | string | User-facing label |
| `client_id` | string | Encrypted — TrueLayer developer client ID |
| `client_secret` | string | Encrypted — TrueLayer developer client secret |
| `access_token` | string | Encrypted — OAuth2 access token |
| `refresh_token` | string | Encrypted — OAuth2 refresh token |
| `token_expires_at` | datetime | When access token expires |
| `status` | string | `good` / `requires_update` |
| `sandbox` | boolean | `true` = sandbox, `false` = production |
| `scheduled_for_deletion` | boolean | Soft-delete flag |
| `last_psu_ip` | string | Stored on sync trigger; used as `X-PSU-IP` header to avoid 4 calls/day rate limit |

### `truelayer_accounts` table

One row per bank account or card within a connection.

| Column | Type | Notes |
|--------|------|-------|
| `truelayer_item_id` | uuid | FK |
| `account_id` | string | TrueLayer's stable account identifier |
| `account_kind` | string | `account` (debit) or `card` (credit) |
| `name` | string | `display_name` from API |
| `account_type` | string | e.g. `TRANSACTION`, `SAVINGS`, `BUSINESS_TRANSACTION`, `BUSINESS_SAVINGS` |
| `currency` | string | ISO currency code |
| `raw_payload` | jsonb | Encrypted — full API response |

`TruelayerAccount` has `has_one :account_provider, as: :provider` and `has_one :account, through: :account_provider`, matching all other provider account models.

---

## TrueLayer API

**Base URLs:**

| Environment | Auth | Data API |
|-------------|------|----------|
| Production | `https://auth.truelayer.com` | `https://api.truelayer.com/data/v1` |
| Sandbox | `https://auth.truelayer-sandbox.com` | `https://api.truelayer-sandbox.com/data/v1` |

**Scopes:** `accounts cards balance transactions offline_access`

**Endpoints used:**

| Endpoint | Purpose |
|----------|---------|
| `POST /connect/token` | Code exchange + token refresh |
| `GET /data/v1/accounts` | List debit/bank accounts |
| `GET /data/v1/cards` | List credit card accounts |
| `GET /data/v1/accounts/{id}/balance` | Account balance |
| `GET /data/v1/cards/{id}/balance` | Card balance |
| `GET /data/v1/accounts/{id}/transactions?from=&to=` | Settled transactions |
| `GET /data/v1/cards/{id}/transactions?from=&to=` | Settled card transactions |
| `GET /data/v1/accounts/{id}/transactions/pending` | Pending transactions |
| `GET /data/v1/cards/{id}/transactions/pending` | Pending card transactions |

**Rate limiting:** Without `X-PSU-IP`, TrueLayer limits to 4 calls/day per account. The syncer passes `X-PSU-IP` from `last_psu_ip` on the item.

**Transaction fields:**
- `transaction_id` — deduplication key
- `timestamp` — ISO 8601 → date
- `merchant_name` (preferred) / `description` (fallback) → payee/notes
- `amount` — decimal; sign-flip for `CREDIT` on cards to match Sure's convention
- `transaction_type` — `DEBIT` / `CREDIT`

**Balance fields:**
- Accounts: `current`, `available`, `overdraft`
- Cards: `current`, `available`, `credit_limit`

---

## Files to Create

| File | Purpose |
|------|---------|
| `app/models/truelayer_item.rb` | Connection model — credentials, tokens, lifecycle |
| `app/models/truelayer_account.rb` | Account/card model — maps to Sure Account |
| `app/models/truelayer_item/syncer.rb` | Orchestrates sync via `account.sync_later` |
| `app/models/truelayer_item/importer.rb` | Fetches accounts, balances, transactions |
| `app/models/truelayer_item/sync_complete_event.rb` | Broadcasts sync completion |
| `app/models/truelayer_entry/processor.rb` | Deduplicates and upserts transactions |
| `app/models/provider/truelayer.rb` | HTTP client — wraps TrueLayer Data API |
| `app/models/provider/truelayer_adapter.rb` | Plugs into `Provider::Factory` |
| `app/controllers/truelayer_items_controller.rb` | OAuth flow + account setup |
| `db/migrate/..._create_truelayer_tables.rb` | One migration covering both tables |
| `app/views/truelayer_items/` | Setup, account mapping, provider panel views |
| `config/locales/views/truelayer_items/en.yml` | i18n strings |
| `app/jobs/sync_truelayer_scheduled_job.rb` | Scheduled sync job |

---

## OAuth Flow

### Connect flow

1. **`new`** — form: `name`, `client_id`, `client_secret`, `sandbox` toggle
2. **`create`** — saves item, redirects to TrueLayer auth URL:
   ```
   https://auth.truelayer.com/?response_type=code
     &client_id={client_id}
     &scope=accounts+cards+balance+transactions+offline_access
     &redirect_uri={callback_url}
     &state={item_id}
   ```
   Sandbox swaps auth base URL.
3. **`callback`** — exchanges `code` for tokens via `POST /connect/token`, stores `access_token`, `refresh_token`, `token_expires_at`, imports accounts → redirects to `setup_accounts`
4. **`setup_accounts`** — user maps each `TruelayerAccount` to a Sure account (create new or link existing)

### Reauth flow (expired tokens)

5. **`reauthorize`** — rebuilds auth URL for items with `status: requires_update`
6. **`reauth_callback`** — verifies `status: requires_update`, exchanges new code, updates tokens, clears status

### Destroy

7. **`destroy`** — destroys `TruelayerItem`; soft-delete via `scheduled_for_deletion` + background job

---

## Sync Architecture

### `TruelayerItem::Syncer`

1. Check `token_expires_at`; if expired or within 60s, call `Provider::Truelayer#refresh_token`
2. On `invalid_grant` → set `status: :requires_update`, raise (sync fails gracefully)
3. Call `TruelayerItem::Importer.new(self).import`
4. Schedule `account.sync_later` for each linked Sure account

### `TruelayerItem::Importer`

1. `GET /accounts` + `GET /cards` — upsert `TruelayerAccount` records by `account_id`; set `account_kind`
2. For each account: fetch balance, update `TruelayerAccount`
3. For each account: fetch settled transactions + pending transactions (date windowed)
4. Pass to `TruelayerEntry::Processor`

Passes `X-PSU-IP: {last_psu_ip}` on all requests.

### `TruelayerEntry::Processor`

- Deduplication key: `transaction_id`
- Payee: `merchant_name` → fallback `description`
- Date: `timestamp` parsed to date
- Amount: flip sign for `CREDIT` transactions on cards
- Pending: `status` from pending endpoint → stored as `extra["truelayer"]["pending"] = true`, matching existing provider pending pattern

---

## Provider::Truelayer (HTTP client)

```ruby
Provider::Truelayer.new(
  client_id:,
  client_secret:,
  access_token:,
  sandbox: false
)
```

Methods:
- `auth_url(redirect_uri:, state:)` — builds authorization URL
- `exchange_code(code:, redirect_uri:)` — returns `{access_token, refresh_token, expires_in}`
- `refresh_token(refresh_token:)` — returns new token set
- `get_accounts(psu_ip: nil)`
- `get_cards(psu_ip: nil)`
- `get_balance(account_id:, kind:, psu_ip: nil)` — routes to accounts or cards endpoint
- `get_transactions(account_id:, kind:, from:, to:, psu_ip: nil)`
- `get_pending_transactions(account_id:, kind:, psu_ip: nil)`

Error handling mirrors Enable Banking: typed `TruelayerError` with `error_type` matching HTTP status codes.

---

## Provider::TruelayerAdapter

Plugs into `Provider::Factory`:
```ruby
Provider::Factory.register("TruelayerAccount", self)
```

Implements `Provider::Base` interface: `provider_name`, `supported_account_types`, `connection_configs`, `sync_path`, `item`.

---

## Pending Transactions

Supported via separate `/transactions/pending` endpoints. Stored in `extra["truelayer"]["pending"]`, consistent with SimpleFIN and Plaid patterns already in the app.
