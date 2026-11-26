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

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (pagination, errors, accounts, categories, merchants, tags), and security definitions.

## Filtering options

The `GET /api/v1/transactions` endpoint supports the following query parameters for filtering:

| Parameter | Type | Description |
| --- | --- | --- |
| `page` | integer | Page number (default: 1) |
| `per_page` | integer | Items per page (default: 25, max: 100; larger values are capped at 100) |
| `account_id` | uuid | Filter by a single account ID |
| `account_ids[]` | uuid[] | Filter by multiple account IDs |
| `category_id` | uuid | Filter by a single category ID (subcategories are not included) |
| `category_ids[]` | uuid[] | Filter by multiple category IDs |
| `merchant_id` | uuid | Filter by a single merchant ID |
| `merchant_ids[]` | uuid[] | Filter by multiple merchant IDs |
| `tag_ids[]` | uuid[] | Transactions carrying any of these tags |
| `start_date` | date | Filter transactions from this date (inclusive), `YYYY-MM-DD` |
| `end_date` | date | Filter transactions until this date (inclusive), `YYYY-MM-DD` |
| `min_amount` | number | Minimum signed amount, inclusive (inflows are negative) |
| `max_amount` | number | Maximum signed amount, inclusive |
| `type` | string | `income` (negative amounts) or `expense` (positive amounts), transfers included |
| `search` | string | Search by name, notes, or merchant name; surrounding spaces are ignored |
| `budget_id` | uuid | Only transactions the budget's category drill-down lists (see below) |
| `exclude_split_parents` | boolean | `true` leaves out transactions that have been split; their split children are still listed |
| `excluded` | boolean | Filters on the entry excluded flag only: `false` lists entries not flagged excluded, `true` only flagged ones (split parents included). Without `budget_id`, this flag alone does not apply the report eligibility rules. With `budget_id`, the budget reporting rules apply independently, so `excluded=true` returns no rows. Omit to leave this flag unfiltered |

Filters combine, so `budget_id` can be narrowed further with `category_id`, `account_id`, a date range and so on. A single id and its list (`account_id` and `account_ids[]`, and likewise for categories and merchants) match the ids in both.

A parameter that is present must be valid, or the request returns `422`: ids must be UUIDs written with hyphens, dates `YYYY-MM-DD`, amounts plain or scientific numbers of at most 20 digits written out (`1e19` is the largest power of ten), `type` `income` or `expense` (case aside), and `exclude_split_parents` / `excluded` one of `true`, `false`, `1` or `0` (case and surrounding spaces aside). An empty value is invalid too, except for `search`, where it turns the search off. Leave a parameter out, or send it with no `=` (`?excluded`, `?tag_ids[]`), to turn its filter off.

### Budget and report lists

`budget_id` returns the rows the web budget category drill-down lists for that budget:

- transactions dated within the budget's period;
- on the accounts the budget's spending is computed from: for the household budget, the caller's finance accounts (owned accounts and shared accounts with `include_in_finances: true`) that are included in reports; for a personal budget, its owner's accounts that are included in reports;
- and, as everywhere in this API, only on accounts the caller can access. A shared personal budget does not share the owner's accounts, so a viewer only sees the rows on accounts the owner has also shared with them, and the list can then add up to less than the budget's spending;
- leaving out the `funds_movement`, `cc_payment` and `one_time` kinds, which budgets ignore, and `investment_contribution` too when the family does not count investing as spending.

The budget must be one `GET /api/v1/budgets/{id}` would return to the caller (the household budget, the caller's own, or one shared with them); any other id returns `404`. Unlike the unfiltered list, rows on disabled accounts are left out, as they are on the web.

The budget list uses the totals' reporting rules: excluded and split-parent entries, pending and future-dated transactions, tax-advantaged accounts, and internal investment transfers/sweeps/exchanges are omitted. Only accounts included in the budget income statement count. For a leaf category, `category_id` selects that line's rows. A parent line's actual spending includes its subcategories, while `category_id` matches only one category: use `category_ids[]` with the parent and its subcategory IDs to include the entire parent line. These rows reconcile with the line's actual spending when the caller can access all of its accounts and no additional filters narrow the results.

## Transaction object

A transaction response includes:

```json
{
  "id": "uuid",
  "entry_id": "uuid",
  "date": "2024-01-15",
  "amount": "$75.50",
  "amount_cents": 7550,
  "signed_amount_cents": -7550,
  "amount_decimal": "75.5",
  "currency": "USD",
  "name": "Grocery shopping",
  "notes": "Weekly groceries",
  "classification": "expense",
  "kind": "standard",
  "excluded": false,
  "split_parent": false,
  "investment_activity_label": null,
  "provider_type": null,
  "security_id": null,
  "exchange_rate": null,
  "amount_currency": "USD",
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

### Amounts, kind and exclusion

| Field | Description |
| --- | --- |
| `amount` | Formatted for display and rounded to the currency's precision. Don't parse it. |
| `amount_cents` / `signed_amount_cents` | Integer minor units, also rounded. |
| `amount_decimal` | The exact stored amount as an unrounded decimal string (for example `"12.3456"`), independent of locale. Positive is an outflow, negative an inflow. Use it when the amount has to match exactly, such as the split amounts sent to `POST /api/v1/transactions/{id}/split`. |
| `kind` | One of `standard`, `funds_movement`, `cc_payment`, `loan_payment`, `one_time`, `investment_contribution`. Budgets and reports count `loan_payment` as an expense whatever the sign of its amount, and leave `funds_movement`, `cc_payment` and `one_time` out. `investment_contribution` also counts as an expense when the family counts investment contributions as spending (the default); when that setting is off it is reported as invested and left out of spending and income. `classification` only follows the amount's sign. |
| `excluded` | `true` when the transaction is left out of budget and report totals. |
| `split_parent` | `true` when the transaction has been split. Splitting a transaction marks it excluded, and its split children carry the amount. |

### Investment activity and provider fields

These are `null` on most transactions. They are set on brokerage cash rows, such as dividends, interest, fees and withholding tax, by the providers that record them.

| Field | Description |
| --- | --- |
| `investment_activity_label` | The investment activity of the row, such as `Dividend`, `Interest` or `Fee`. |
| `provider_type` | The importing provider's type for the row, for example IBKR's `"Withholding Tax"`. Use it to tell rows apart that share a label. IBKR, Trading 212, Wise, Akahu and Kraken store the provider's own type. For CoinSpot, Sure sets it from the kind of movement, such as `"receive"` or `"send"`. Only this value is exposed; the provider's raw payload is not. |
| `security_id` | The id of the Sure security the row relates to, such as the one that paid a dividend, or `null`. `GET /api/v1/securities/{id}` finds it only when one of your accounts holds or has traded that security; otherwise that lookup returns 404. |
| `exchange_rate` | The rate from the transaction's currency to the account's currency stored on the row, such as one reported by the provider. `null` when none is stored, and when the transaction is in the account's currency, since no conversion applies. |
| `amount_currency` | The currency of the amount. On a transaction it is always the same as `currency`, which `exchange_rate` converts from. |

### Linking to a transaction

`id` identifies the transaction in the API. Web routes for a single transaction take the id of its entry instead, so use `entry_id` to link into the app, for example `/transactions/{entry_id}`.

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
