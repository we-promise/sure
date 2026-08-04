# Transactions API Documentation

The Transactions API allows external applications to manage financial transactions within Sure. The OpenAPI description is generated directly from executable request specs, ensuring it always reflects the behaviour of the running Rails application.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/transactions_spec.rb`](../../spec/requests/api/v1/transactions_spec.rb). These specs authenticate against the Rails stack, exercise every transaction endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/transactions_spec.rb
  ```

## Authentication requirements

All transaction endpoints require an OAuth2 access token or API key that grants the appropriate scope (`read` or `read_write`).

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/transactions` | `read` | List transactions with filtering and pagination. |
| `GET /api/v1/transactions/{id}` | `read` | Retrieve a single transaction with full details. |
| `POST /api/v1/transactions` | `read_write` | Create a new transaction. |
| `PATCH /api/v1/transactions/{id}` | `read_write` | Update an existing transaction. |
| `DELETE /api/v1/transactions/{id}` | `read_write` | Permanently delete a transaction. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (pagination, errors, accounts, categories, merchants, tags), and security definitions.

## Filtering options

The `GET /api/v1/transactions` endpoint supports the following query parameters for filtering:

| Parameter | Type | Description |
| --- | --- | --- |
| `page` | integer | Page number (default: 1) |
| `per_page` | integer | Items per page (default: 25, max: 100) |
| `account_id` | uuid | Filter by a single account ID |
| `account_ids[]` | uuid[] | Filter by multiple account IDs |
| `category_id` | uuid | Filter by a single category ID |
| `category_ids[]` | uuid[] | Filter by multiple category IDs |
| `merchant_id` | uuid | Filter by a single merchant ID |
| `merchant_ids[]` | uuid[] | Filter by multiple merchant IDs |
| `tag_ids[]` | uuid[] | Filter by tag IDs |
| `start_date` | date | Filter transactions from this date (inclusive) |
| `end_date` | date | Filter transactions until this date (inclusive) |
| `min_amount` | number | Filter by minimum amount |
| `max_amount` | number | Filter by maximum amount |
| `type` | string | Filter by transaction type: `income` or `expense` |
| `search` | string | Search by name, notes, or merchant name |

## Transaction object

A transaction response includes:

```json
{
  "id": "uuid",
  "date": "2024-01-15",
  "amount": "$75.50",
  "amount_cents": 7550,
  "signed_amount_cents": -7550,
  "currency": "USD",
  "name": "Grocery shopping",
  "notes": "Weekly groceries",
  "external_id": null,
  "source": null,
  "classification": "expense",
  "account": {
    "id": "uuid",
    "name": "Checking Account",
    "account_type": "depository"
  },
  "category": {
    "id": "uuid",
    "name": "Groceries",
    "color": "#4CAF50",
    "icon": "shopping-cart"
  },
  "merchant": {
    "id": "uuid",
    "name": "Whole Foods"
  },
  "tags": [
    {
      "id": "uuid",
      "name": "Essential",
      "color": "#2196F3"
    }
  ],
  "transfer": null,
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

### Amount fields

`amount` is a localized, currency-formatted **string** and follows an accounting sign convention (expenses positive, income negative). For programmatic use prefer the integer minor-unit fields:

| Field | Description |
| --- | --- |
| `amount_cents` | Absolute value in minor units, using the currency's own conversion factor (100 for USD/EUR, 1 for JPY, 1000 for KWD). Always positive. |
| `signed_amount_cents` | Same magnitude, signed so that **income is positive and expenses are negative** — the opposite convention to `amount`. |

`external_id` and `source` echo the idempotency key a transaction was created with, and are `null` for transactions created without one.

## Creating transactions

When creating a transaction, the `nature` field determines how the amount is stored:

| Nature | Behaviour |
| --- | --- |
| `income` / `inflow` | The absolute amount is stored as negative (credit) |
| `expense` / `outflow` | The absolute amount is stored as positive (debit) |
| omitted or unrecognised | The `amount` is stored exactly as provided, sign included |

Note that `nature` has **no default**. If you omit it, the sign of `amount` is preserved as sent rather than coerced — so send either a `nature` or an already-signed `amount`, not an unsigned amount alone.

Example request body:

```json
{
  "transaction": {
    "account_id": "uuid",
    "date": "2024-01-15",
    "amount": 75.50,
    "name": "Grocery shopping",
    "nature": "expense",
    "category_id": "uuid",
    "merchant_id": "uuid",
    "tag_ids": ["uuid", "uuid"]
  }
}
```

### Idempotent creates

To make retries safe, send an `external_id` in the create body. Sure stores it on the entry together with a `source` and treats the pair as an idempotency key scoped to the account:

```json
{
  "transaction": {
    "account_id": "uuid",
    "date": "2024-01-15",
    "amount": 75.50,
    "name": "Grocery shopping",
    "nature": "expense",
    "external_id": "ledger-row-40817",
    "source": "my-importer"
  }
}
```

- `source` is optional and defaults to `"api"`.
- A first request returns `201 Created`.
- A replay with the same `external_id` + `source` for the same account returns **`200 OK`** with the originally created transaction, and does not create a duplicate. Use the status code to distinguish a create from a replay.
- If the stored `external_id` belongs to a non-transaction entry (a trade or valuation), the request returns `422 Unprocessable Entity`.

## Split transactions

Transactions that participate in a split are restricted through this API — use the split editor in the web UI instead. Both cases return `422 Unprocessable Entity`:

| Attempt | Result |
| --- | --- |
| `PATCH` or `DELETE` on a split **child** | Rejected. Children cannot be edited or deleted individually. |
| `PATCH` on a split **parent** changing `amount`, `date`, or `nature` | Rejected. Other fields (name, notes, category, merchant, tags) can still be updated. |

## Transfer transactions

If a transaction is part of a transfer between accounts, the `transfer` field will be populated with details about the linked transaction:

```json
{
  "transfer": {
    "id": "uuid",
    "amount": "$500.00",
    "currency": "USD",
    "other_account": {
      "id": "uuid",
      "name": "Savings Account",
      "account_type": "depository"
    }
  }
}
```

## Error responses

Errors conform to the shared `ErrorResponse` schema in the OpenAPI document:

```json
{
  "error": "error_code",
  "message": "Human readable error message",
  "errors": ["Optional array of validation errors"]
}
```

Common error codes include `unauthorized`, `not_found`, `validation_failed`, and `internal_server_error`.
