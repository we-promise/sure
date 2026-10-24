# Transactions API Documentation

The Transactions API allows external applications to manage financial transactions within Sure. The OpenAPI description is generated directly from executable request specs, ensuring it always reflects the behaviour of the running Rails application.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/transactions_spec.rb`](../../spec/requests/api/v1/transactions_spec.rb). These specs authenticate against the Rails stack, exercise every transaction endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  SWAGGER_DRY_RUN=0 bundle exec rspec spec/requests --format Rswag::Specs::SwaggerFormatter
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
| `POST /api/v1/transactions` | `write` | Create a new transaction. |
| `PATCH /api/v1/transactions/{id}` | `write` | Update an existing transaction. |
| `DELETE /api/v1/transactions/{id}` | `write` | Permanently delete a transaction. |
| `POST /api/v1/transactions/auto_categorize` | `write` | Queue AI auto-categorization for uncategorized transactions. |

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
  "currency": "USD",
  "name": "Grocery shopping",
  "notes": "Weekly groceries",
  "classification": "expense",
  "account": {
    "id": "uuid",
    "name": "Checking Account",
    "account_type": "depository"
  },
  "category": {
    "id": "uuid",
    "name": "Groceries",
    "classification": "expense",
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

## Creating transactions

When creating a transaction, the `nature` field determines how the amount is stored:

| Nature | Behaviour |
| --- | --- |
| `income` / `inflow` | Amount is stored as negative (credit) |
| `expense` / `outflow` | Amount is stored as positive (debit) |

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

## Auto-categorizing transactions

`POST /api/v1/transactions/auto_categorize` queues AI categorization in the background, the same work the "Auto-categorize transactions with AI" rule action does. It uses the family's configured categorization provider and confidence threshold, and picks from the family's existing categories. It returns `422 validation_failed` when no provider is configured, the family has no categories, or the request is malformed (`transaction_ids` that is not a non-empty array of transaction IDs or has more than 1,000 entries, an invalid `after_transaction_id`, or both fields sent together).

Send `transaction_ids` (up to 1,000 entries, duplicates included) to categorize specific transactions. IDs are matched case-insensitively and returned in lowercase:

```json
{
  "transaction_ids": ["uuid", "uuid"]
}
```

Omit `transaction_ids` to queue eligible transactions in pages of at most 1,000, ordered by ID. When more were eligible, `truncated` is `true` and `next_after_transaction_id` holds the last ID considered: send it back as `after_transaction_id` to queue the next page. Paging matters because a transaction the provider finds no confident match for stays uncategorized and eligible, so repeating the request without the cursor would pick the same page again.

```json
{
  "after_transaction_id": "uuid"
}
```

Only uncategorized transactions on accounts the key's user may annotate are queued. Transactions whose category is locked (set or cleared by hand), transfers between the family's own accounts, and split parents are skipped; the job checks this again when it runs, so a transaction that became a transfer or split parent in the meantime is not categorized. The response is `202 Accepted`:

```json
{
  "queued_count": 1,
  "transaction_ids": ["uuid"],
  "skipped_transaction_ids": ["uuid"],
  "truncated": false,
  "next_after_transaction_id": null
}
```

`skipped_transaction_ids` lists requested IDs that were not queued, for any of the reasons above (it is always empty when `transaction_ids` is omitted).

A `202` means the jobs were queued, not that categories were assigned. A job can fail, or the provider can find no match above the confidence threshold, so a queued transaction may stay uncategorized. Read the results back with `GET /api/v1/transactions/{id}` once the jobs have run.

If the job queue refuses a batch, the response is `503` with `error` (`service_unavailable`), `message`, `queued_count`, `transaction_ids` (the ones that were queued), `unqueued_transaction_ids`, `skipped_transaction_ids`, `truncated` and `next_after_transaction_id`. Retry with `unqueued_transaction_ids` as the new `transaction_ids`; repeating the original request would queue the already accepted transactions a second time, since they stay uncategorized until their jobs run.

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
