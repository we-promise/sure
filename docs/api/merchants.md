# Merchants API

The Merchants API allows external applications to retrieve merchants within Sure. Merchants represent payees or vendors associated with transactions.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/merchants_spec.rb`](../../spec/requests/api/v1/merchants_spec.rb). These specs authenticate against the Rails stack, exercise every merchant endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  SWAGGER_DRY_RUN=0 bundle exec rspec spec/requests --format Rswag::Specs::SwaggerFormatter
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/merchants_spec.rb
  ```

## Authentication requirements

All merchant endpoints require an OAuth2 access token or API key that grants the `read` scope.

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/merchants` | `read` | List all merchants available to the family. |
| `GET /api/v1/merchants/{id}` | `read` | Retrieve a single merchant by ID. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components, and security definitions.

## Merchant types

Sure supports two types of merchants:

| Type | Description |
| --- | --- |
| `FamilyMerchant` | Merchants created and owned by the family. |
| `ProviderMerchant` | Merchants from external providers (e.g., Plaid) assigned to transactions. |

The `GET /api/v1/merchants` endpoint returns both types: all family merchants plus any provider merchants that are assigned to the family's transactions.

## Merchant object

A merchant response includes:

```json
{
  "id": "uuid",
  "name": "Whole Foods",
  "type": "FamilyMerchant",
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

## Listing merchants

Example request:

```http
GET /api/v1/merchants
Authorization: Bearer <access_token>
```

Example response:

```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440001",
    "name": "Amazon",
    "type": "FamilyMerchant",
    "created_at": "2024-01-10T08:00:00Z",
    "updated_at": "2024-01-10T08:00:00Z"
  },
  {
    "id": "550e8400-e29b-41d4-a716-446655440002",
    "name": "Starbucks",
    "type": "ProviderMerchant",
    "created_at": "2024-01-12T14:30:00Z",
    "updated_at": "2024-01-12T14:30:00Z"
  }
]
```

## Using merchants with transactions

When creating or updating transactions, you can assign a merchant using the `merchant_id` field:

```json
{
  "transaction": {
    "account_id": "uuid",
    "date": "2024-01-15",
    "amount": 75.50,
    "name": "Coffee",
    "nature": "expense",
    "merchant_id": "550e8400-e29b-41d4-a716-446655440002"
  }
}
```

## Error responses

Errors conform to the shared `ErrorResponse` schema in the OpenAPI document:

```json
{
  "error": "Human readable error message"
}
```

Common error codes include `unauthorized`, `not_found`, and `internal_server_error`.
