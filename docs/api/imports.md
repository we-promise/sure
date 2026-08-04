# Imports API Documentation

The Imports API allows external applications to programmatically upload and process financial data from CSV files. This API supports creating transaction imports, configuring column mappings, and triggering the import process.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/imports_spec.rb`](../../spec/requests/api/v1/imports_spec.rb). These specs authenticate against the Rails stack, exercise every import endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/imports_spec.rb
  ```

## Authentication requirements

All import endpoints require an OAuth2 access token or API key that grants the appropriate scope (`read` or `read_write`).

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/imports` | `read` | List imports with filtering and pagination. |
| `GET /api/v1/imports/{id}` | `read` | Retrieve a single import with configuration and statistics. |
| `GET /api/v1/imports/{id}/rows` | `read` | List the parsed rows of an import, paginated, with per-row validation state. |
| `POST /api/v1/imports/preflight` | `read` | Dry-run a CSV against a configuration and inspect the detected mapping without creating an import. |
| `POST /api/v1/imports` | `read_write` | Create a new import and optionally trigger processing. |

`POST /api/v1/imports/preflight` accepts the same parameters as create (`type`, `account_id`, `file` or `raw_file_content`, plus every column-mapping key) and returns the detected configuration and row statistics. Preflight is not supported for `PdfImport` or `QifImport`.

### Related: chunked uploads

For files too large to send in a single request, the `/api/v1/import_sessions` endpoints (`POST` to create, `POST /{id}/chunks` to append, `POST /{id}/publish` to finalise) provide a chunked upload flow. See [`openapi.yaml`](openapi.yaml) for their schemas.

## Filtering options

The `GET /api/v1/imports` endpoint supports the following query parameters:

| Parameter | Type | Description |
| --- | --- | --- |
| `page` | integer | Page number (default: 1) |
| `per_page` | integer | Items per page (default: 25, max: 100) |
| `status` | string | Filter by status: `pending`, `importing`, `complete`, `failed`, `reverting`, `revert_failed` |
| `type` | string | Filter by import type. See the full list below. |

### Import types

`TransactionImport`, `TradeImport`, `AccountImport`, `MintImport`, `ActualImport`, `YnabImport`, `CategoryImport`, `RuleImport`, `MerchantImport`, `PdfImport`, `QifImport`, `SureImport`.

On create, an unrecognised `type` is **not** rejected — it silently falls back to `TransactionImport`. `SureImport` follows a separate code path and expects a Sure export archive rather than a mapped CSV.

## Import object

An import response includes configuration and processing statistics:

```json
{
  "data": {
    "id": "uuid",
    "type": "TransactionImport",
    "status": "pending",
    "created_at": "2024-01-15T10:30:00Z",
    "updated_at": "2024-01-15T10:30:00Z",
    "account_id": "uuid",
    "status_detail": {},
    "configuration": {
      "date_col_label": "date",
      "amount_col_label": "amount",
      "name_col_label": "name",
      "category_col_label": "category",
      "tags_col_label": "tags",
      "notes_col_label": "notes",
      "account_col_label": null,
      "date_format": "%m/%d/%Y",
      "number_format": "1,234.56",
      "signage_convention": "inflows_positive"
    },
    "stats": {
      "rows_count": 150,
      "valid_rows_count": 148,
      "invalid_rows_count": 2,
      "mappings_count": 12,
      "unassigned_mappings_count": 1
    }
  }
}
```

`error` is present only when the import failed. `verification` is present only for `SureImport`. `status_detail` carries a human-readable progress breakdown, including validation stats on the single-import endpoint.

The list endpoint returns a flatter object per import (no `configuration`, no `stats` — but a top-level `rows_count`) and paginates under a **`meta`** key rather than the `pagination` key used elsewhere in the API:

```json
{
  "data": [ { "id": "uuid", "type": "TransactionImport", "status": "pending", "rows_count": 150, "status_detail": {} } ],
  "meta": {
    "current_page": 1,
    "next_page": 2,
    "prev_page": null,
    "total_pages": 4,
    "total_count": 87,
    "per_page": 25
  }
}
```

## Creating an import

When creating an import, you must provide the file content and the column mappings.

### Parameters

All parameters are sent at the top level of the request body (they are not nested under an `import` key).

#### File and target

| Parameter | Type | Description |
| --- | --- | --- |
| `raw_file_content` | string | The raw CSV content as a string. |
| `file` | file | Alternatively, the CSV file can be uploaded as a multipart form-data part. |
| `type` | string | Import type. Defaults to `TransactionImport`; unrecognised values fall back to it silently. |
| `account_id` | uuid | Optional. The ID of the account to import into. |
| `publish` | boolean | If `true` (as the string `"true"`), the import is queued for processing once its configuration is valid. |

#### Column mappings

| Parameter | Type | Description |
| --- | --- | --- |
| `date_col_label` | string | Header name for the date column. |
| `amount_col_label` | string | Header name for the amount column. |
| `name_col_label` | string | Header name for the transaction name column. |
| `category_col_label` | string | Header name for the category column. |
| `tags_col_label` | string | Header name for the tags column. |
| `notes_col_label` | string | Header name for the notes column. |
| `account_col_label` | string | Header name for the account column, for multi-account files. |
| `currency_col_label` | string | Header name for the currency column. |
| `qty_col_label` | string | Header name for the quantity column (trade imports). |
| `ticker_col_label` | string | Header name for the ticker column (trade imports). |
| `price_col_label` | string | Header name for the price column (trade imports). |
| `exchange_operating_mic_col_label` | string | Header name for the exchange MIC column (trade imports). |
| `entity_type_col_label` | string | Header name for the entity type column. |

#### Parsing options

| Parameter | Type | Description |
| --- | --- | --- |
| `date_format` | string | strftime format for parsing dates, e.g. `%m/%d/%Y`. |
| `number_format` | string | Expected numeric format, e.g. `1,234.56`. |
| `signage_convention` | string | `inflows_positive` or `inflows_negative`. |
| `col_sep` | string | Column separator: `,` or `;`. |
| `rows_to_skip` | integer | Number of leading rows to skip before the header. |
| `amount_type_strategy` | string | How to derive inflow/outflow when the file uses a separate type column. |
| `amount_type_inflow_value` | string | The value in that column that marks an inflow. |

Example request body:

```json
{
  "raw_file_content": "date,amount,name\n01/01/2024,10.00,Test",
  "date_col_label": "date",
  "amount_col_label": "amount",
  "name_col_label": "name",
  "account_id": "uuid",
  "publish": "true"
}
```

## Error responses

Errors conform to the shared `ErrorResponse` schema:

```json
{
  "error": "error_code",
  "message": "Human readable error message",
  "errors": ["Optional array of validation errors"]
}
```

Import-specific error codes:

| Code | Status | Meaning |
| --- | --- | --- |
| `file_too_large` | 422 | Uploaded file exceeds the maximum CSV size. |
| `content_too_large` | 422 | `raw_file_content` exceeds the maximum CSV size. |
| `invalid_file_type` | 422 | Uploaded file is not a recognised CSV MIME type. |
| `invalid_csv` | 422 | CSV content could not be parsed (preflight). |
| `validation_failed` | 422 | The import could not be created; see `errors`. |
| `not_found` | 404 | Import does not exist or belongs to another family. |

