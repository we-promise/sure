---
name: sure-api
description: >-
  Use Sure's REST API (/api/v1) with an API key or OAuth token: list and
  filter transactions, create and update them, and read accounts, balances,
  budgets, categories, holdings, imports and exports, with the OpenAPI spec
  generated from request specs. Use when scripting against a Sure instance
  or extending its API.
---

# Sure REST API

References: `docs/api/openapi.yaml`, `docs/api/transactions.md` and the
other files in `docs/api/`.

## Auth

Generate an API key in account settings and send it as `X-Api-Key`, or
use an OAuth2 access token. Scopes: `read` or `read_write`.

```bash
export SURE=http://localhost:3000 KEY=...
curl -s "$SURE/api/v1/accounts" -H "X-Api-Key: $KEY"
```

## Transactions

```bash
curl -s "$SURE/api/v1/transactions?start_date=2026-01-01&end_date=2026-01-31&type=expense&per_page=100" \
  -H "X-Api-Key: $KEY"
curl -s "$SURE/api/v1/transactions/<id>" -H "X-Api-Key: $KEY"
```

Filters: `page`, `per_page` (max 100), `account_id`/`account_ids[]`,
`category_id(s)`, `merchant_id(s)`, `tag_ids[]`, `start_date`, `end_date`,
`min_amount`, `max_amount`, `type` (`income`/`expense`), `search`.

`POST`, `PATCH` and `DELETE /api/v1/transactions[/{id}]` need a write
scope. Amounts: `amount_decimal` is exact (positive = outflow, negative =
inflow); `amount` is a formatted display string. Confirm with the user
before writes or deletes.

## Other resources

`accounts`, `balances`, `balance_sheet`, `cash_flow`, `budgets`,
`budget_categories`, `categories`, `holdings`, `imports`,
`import_sessions`, `account_statements`, `family_exports`, `chats` and
more; see `docs/api/openapi.yaml` for schemas and the per-resource docs.

## Changing the API

The OpenAPI file is generated from rswag request specs in
`spec/requests/api/v1/`. After changing an endpoint, update its spec and
regenerate:

```bash
SWAGGER_DRY_RUN=0 bundle exec rspec spec/requests --format Rswag::Specs::SwaggerFormatter
```
