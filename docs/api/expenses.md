# Expenses API Documentation

The Expenses API lets external clients create and manage expense transactions in Sure. Expenses are created through the transactions endpoint and recorded against a family account with categories, merchants, tags, and (soon) spenders.

## Authentication

All endpoints require authentication via **OAuth 2.0** or **API keys**:

- **OAuth 2.0**: Send a Bearer token in the `Authorization` header. The token must include the `read_write` scope for creating expenses.
  ```http
  Authorization: Bearer <access_token>
  Content-Type: application/json
  Accept: application/json
  ```
- **API Key**: Provide your key in the `X-Api-Key` header. The key must be active and provisioned with the `read_write` scope for write operations.
  ```http
  X-Api-Key: <your_api_key>
  Content-Type: application/json
  Accept: application/json
  ```

API key requests are rate limited; responses include `X-RateLimit-*` headers. If the limit is exceeded, the API returns `429 rate_limit_exceeded`.

## Endpoint

```http
POST /api/v1/transactions
```

**Required scope:** `read_write` (write). Read-only clients should omit this endpoint and use the transactions listing once available.

## Request Body

Send a JSON payload under the `transaction` key. Fields are optional unless marked **required**.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `account_id` | string/UUID | **Yes** | Destination account that owns the expense. |
| `amount` | number | **Yes** | Positive value representing the expense amount. Sign handling is automatic (see Currency & amounts). |
| `date` | string (ISO 8601) | Recommended | Posting date, e.g., `2024-07-15`. |
| `name` | string | Recommended | Display name for the entry. Falls back to `description` if omitted. |
| `description` | string | Optional | Alternative to `name`. |
| `notes` | string | Optional | Free-form notes. |
| `currency` | string (ISO code) | Optional | Defaults to the family currency if omitted. |
| `category_id` | string/UUID | Optional | Expense category to associate. |
| `merchant_id` | string/UUID | Optional | Merchant reference, if tracked. |
| `tag_ids` | array[string/UUID] | Optional | Tag IDs to attach. |
| `nature` | string | Optional | Use `"expense"` or `"outflow"` to ensure the amount is treated as an expense. |
| `spender_id` | string/UUID | Upcoming | Reserved for the forthcoming spender field. When available, set this to the spender/user responsible for the expense to enable per-person reporting. |

### Example: API key

```bash
curl -X POST \
  -H "X-Api-Key: sk_live_example" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "transaction": {
      "account_id": "3f0b2ce0-5b5c-4b5a-9f3e-7a2d9e8c6b9b",
      "amount": 120.45,
      "nature": "expense",
      "date": "2024-07-15",
      "currency": "USD",
      "name": "Groceries",
      "category_id": "bb8a2fe4-96ba-4f6c-9c8c-a1c5d6e2f170",
      "tag_ids": ["c2b8b81d-0b85-4b2d-8d5b-90f9d2ab0c5c"]
    }
  }' \
  https://api.sure.am/api/v1/transactions
```

### Example: OAuth 2.0

```bash
curl -X POST \
  -H "Authorization: Bearer 4a9ad5..." \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "transaction": {
      "account_id": "3f0b2ce0-5b5c-4b5a-9f3e-7a2d9e8c6b9b",
      "amount": 19.99,
      "nature": "outflow",
      "date": "2024-07-14",
      "name": "Coffee run",
      "merchant_id": "0e0b4c0e-4e5a-4c86-9efc-bc174e6dc9b2",
      "currency": "EUR"
    }
  }' \
  https://api.sure.am/api/v1/transactions
```

## Currency & amounts

- **Default currency**: If `currency` is not provided, the family’s default currency is used.
- **Signed values**: Send expenses as positive numbers and set `nature` to `"expense"` or `"outflow"`. The API will store the correct signed amount for reporting. If you pass `nature: "income"`, the amount is treated as an inflow (negative value internally).
- **Formatting**: Response objects include a human-readable `amount` string (e.g., `$120.45`) and a `currency` code so clients can display or convert values accurately.

## Response

On success, the API returns `201 Created` with the transaction resource:

```json
{
  "id": "e3d95d9a-9d0e-4bd8-9a7a-1f4e0cfa9a3c",
  "date": "2024-07-15",
  "amount": "$120.45",
  "currency": "USD",
  "name": "Groceries",
  "notes": null,
  "classification": "expense",
  "account": {
    "id": "3f0b2ce0-5b5c-4b5a-9f3e-7a2d9e8c6b9b",
    "name": "Checking",
    "account_type": "bank"
  },
  "category": {
    "id": "bb8a2fe4-96ba-4f6c-9c8c-a1c5d6e2f170",
    "name": "Groceries",
    "classification": "expense",
    "color": "#34d399",
    "icon": "shopping-basket"
  },
  "merchant": null,
  "tags": [
    { "id": "c2b8b81d-0b85-4b2d-8d5b-90f9d2ab0c5c", "name": "Family", "color": "#4f46e5" }
  ],
  "transfer": null,
  "created_at": "2024-07-15T14:20:00Z",
  "updated_at": "2024-07-15T14:20:00Z"
}
```

When the spender field is available, responses will also include `spender` details (ID and display name) mirroring the provided `spender_id`.

## Error responses

Errors follow a consistent shape:

```json
{ "error": "validation_failed", "message": "Transaction could not be created", "errors": ["Account ID is required"] }
```

Common cases:

- `401 unauthorized` – Missing or invalid token/api key.
- `403 insufficient_scope` – Token or key lacks the `read_write` scope.
- `404 not_found` – Referenced resource (e.g., category or account) does not exist.
- `422 validation_failed` – Invalid parameters (e.g., missing `account_id`).
- `429 rate_limit_exceeded` – API key exceeded its quota; check `Retry-After` and `X-RateLimit-*` headers.

## Spender field (upcoming)

A `spender_id` attribute will soon let you associate expenses with a spender/person. Plan to:

1. Store the spender’s identifier in your system to map to `spender_id` when creating expenses.
2. Send `spender_id` alongside other transaction attributes; the API will validate it belongs to the same family.
3. Expect responses to include a `spender` object for filtering and reporting once the field ships.
