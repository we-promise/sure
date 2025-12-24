# Imports API Documentation

The Imports API allows external applications to programmatically upload and process financial data from CSV files. This API supports creating transaction imports, configuring column mappings, and triggering the import process.

## Authentication requirements

All import endpoints require an OAuth2 access token or API key that grants the appropriate scope (`read` or `read_write`).

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/imports` | `read` | List imports with filtering and pagination. |
| `GET /api/v1/imports/{id}` | `read` | Retrieve a single import with configuration and statistics. |
| `POST /api/v1/imports` | `read_write` | Create a new import and optionally trigger processing. |

## Filtering options

The `GET /api/v1/imports` endpoint supports the following query parameters:

| Parameter | Type | Description |
| --- | --- | --- |
| `page` | integer | Page number (default: 1) |
| `per_page` | integer | Items per page (default: 25, max: 100) |
| `status` | string | Filter by status: `pending`, `importing`, `complete`, `failed`, `reverting`, `revert_failed` |
| `type` | string | Filter by import type: `TransactionImport`, `TradeImport`, etc. |

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
      "valid_rows_count": 150
    }
  }
}
```

## Creating an import

When creating an import, you must provide the file content and the column mappings.

### Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `raw_file_content` | string | The raw CSV content as a string. |
| `file` | file | Alternatively, the CSV file can be uploaded as a multipart form-data part. |
| `account_id` | uuid | Optional. The ID of the account to import into. |
| `date_col_label` | string | The header name for the date column. |
| `amount_col_label` | string | The header name for the amount column. |
| `name_col_label` | string | The header name for the transaction name column. |
| `publish` | boolean | If `true`, the import will be automatically queued for processing if configuration is valid. |

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

