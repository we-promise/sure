# Account Statements API

The Account Statements API lets external applications file statement documents (PDF, CSV or XLSX) in the Statement Vault and look up what is already there. It is the API counterpart of the vault's upload form and of the `upload_account_statement` / `list_account_statements` assistant tools, and it applies the same rules.

Statements are archived only: uploading one never imports transactions. Use the [Imports API](imports.md) for that.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/account_statements_spec.rb`](../../spec/requests/api/v1/account_statements_spec.rb).
- Regenerate the OpenAPI document with:

  ```sh
  RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
  ```

## Authentication requirements

| Operation | Scope Required |
| --- | --- |
| List/View statements | `read` |
| Upload a statement | `write` |

The Statement Vault is available to admins and members; guests get `403`.

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/account_statements` | `read` | List statements the caller can see, newest first. |
| `GET /api/v1/account_statements/{id}` | `read` | Retrieve a single statement. |
| `POST /api/v1/account_statements` | `write` | Upload a statement (`multipart/form-data`). |

### Visibility

Unlinked statements (the vault inbox) are visible to every admin and member. A statement linked to an account is visible only to people the account is shared with. Statements the caller cannot see are left out of lists and return `404`.

### Uploading

```sh
curl -X POST https://sure.example.com/api/v1/account_statements \
  -H "X-Api-Key: $SURE_API_KEY" \
  -F "file=@2026-03-statement.pdf" \
  -F "account_id=8f0d5c6e-..."
```

- `file` (required): `.pdf`, `.csv` or `.xlsx`, at most 25 MB. The content must match the extension.
- `account_id` (optional): links the statement to this account. It needs write access to the account (owner or full control), as in the app; otherwise the response is `404`. Without it, the statement goes to the vault inbox and the vault suggests a matching account, which someone confirms in the app.

Responses:

| Status | Meaning |
| --- | --- |
| `201` | Stored. `meta.duplicate` is `false`. |
| `200` | The same file (by SHA-256) is already in the vault. The existing statement is returned with `meta.duplicate: true`; nothing is created. |
| `409` | The same file is already in the vault, linked to an account the caller cannot see. No details are returned. |
| `422` | Missing file, unsupported type, or a file that fails validation. |

Uploading the same file again is safe, so clients can retry or re-send without checking first. To check without uploading, list with `content_sha256`.

### Listing filters

| Parameter | Description |
| --- | --- |
| `account_id` | Statements linked to this account. |
| `review_status` | `unmatched`, `linked` or `rejected`. |
| `content_sha256` | The statement for a file, by its SHA-256 (hex). |
| `start_date` | Statements whose period ends on or after this date (`YYYY-MM-DD`). |
| `end_date` | Statements whose period starts on or before this date (`YYYY-MM-DD`). |
| `page`, `per_page` | Pagination (default 25, max 100). |

## Statement object

```json
{
  "data": {
    "id": "uuid",
    "filename": "2026-03-statement.pdf",
    "content_type": "application/pdf",
    "byte_size": 182734,
    "content_sha256": "9f2c...",
    "review_status": "linked",
    "period_start_on": "2026-03-01",
    "period_end_on": "2026-03-31",
    "currency": "USD",
    "opening_balance": "1520.00",
    "closing_balance": "1735.42",
    "institution_name_hint": "Example Bank",
    "account_last4_hint": "1234",
    "account": { "id": "uuid", "name": "Everyday", "currency": "USD" },
    "suggested_account": null,
    "match_confidence": null,
    "created_at": "2026-04-02T09:15:00Z",
    "updated_at": "2026-04-02T09:15:00Z"
  },
  "meta": { "duplicate": false }
}
```

Period, balances and hints are read from the document when possible and may be `null`. `suggested_account` and `match_confidence` are set for unlinked statements when the vault finds a likely account the caller can see.
