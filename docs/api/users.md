# Users API Documentation

The Users API allows external applications to manage user account data within Sure. The OpenAPI description is generated directly from executable request specs, ensuring it always reflects the behaviour of the running Rails application.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/users_spec.rb`](../../spec/requests/api/v1/users_spec.rb). These specs authenticate against the Rails stack, exercise every user endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/users_spec.rb
  ```

## Authentication requirements

All user endpoints require an OAuth2 access token or API key. In addition, both reset endpoints require the authenticated user to be a **family admin**; a non-admin receives `403 forbidden`.

## Available endpoints

| Endpoint | Scope | Admin | Description |
| --- | --- | --- | --- |
| `GET /api/v1/users/reset/status` | `read` | Yes | Check the progress of an in-flight or completed reset. |
| `DELETE /api/v1/users/reset` | `read_write` | Yes | Reset account data while preserving the user account. |
| `DELETE /api/v1/users/me` | `read_write` | No | Permanently delete the user account. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (errors), and security definitions.

## Reset account

`DELETE /api/v1/users/reset`

Resets all financial data (accounts, categories, merchants, tags, transactions, etc.) for the current user's family while keeping the user account intact. The reset runs asynchronously in the background.

### Request

No request body required.

### Response

```json
{
  "message": "Account reset has been initiated",
  "status": "queued",
  "job_id": "uuid",
  "family_id": "uuid",
  "status_url": "/api/v1/users/reset/status"
}
```

If the background job cannot be queued the endpoint returns `500` with the error code `reset_enqueue_failed`.

## Reset status

`GET /api/v1/users/reset/status`

Because the reset runs asynchronously, poll this endpoint to observe progress. It reports the remaining record counts for each resettable model; the reset is finished once they all reach zero.

```json
{
  "status": "data_remaining",
  "family_id": "uuid",
  "reset_complete": false,
  "counts": {
    "accounts": 3,
    "transactions": 128,
    "plaid_items": 1
  }
}
```

`status` is `complete` when `reset_complete` is `true`, and `data_remaining` otherwise.

### Use cases

- Clear all financial data to start fresh
- Remove test data after initial setup
- Reset to a clean state for new imports

## Delete account

`DELETE /api/v1/users/me`

Permanently deactivates the current user account and all associated data. This action cannot be undone.

### Request

No request body required.

### Response

```json
{
  "message": "Account has been deleted"
}
```

### Error responses

In addition to standard error codes (`unauthorized`, `insufficient_scope`), the delete endpoint may return:

**422 Unprocessable Entity**

```json
{
  "error": "Failed to delete account",
  "details": ["Cannot deactivate admin with other users"]
}
```

This occurs when the user cannot be deactivated (for example, an admin user with other active users in the family).

## Security considerations

- Both endpoints require the `read_write` scope. Read-only API keys cannot access these endpoints.
- Deactivated users cannot access these endpoints.
- The reset operation preserves the user account, allowing you to continue using Sure with a clean slate.
- The delete operation is permanent and removes the user account entirely.

## Error responses

Errors conform to the shared `ErrorResponse` schema in the OpenAPI document:

```json
{
  "error": "error_code",
  "message": "Human readable error message",
  "details": ["Optional array of extra context"]
}
```

Common error codes include:

| Code | Description |
| --- | --- |
| `unauthorized` | Missing or invalid API key |
| `insufficient_scope` | API key lacks required `read_write` scope |
| `Failed to delete account` | Account deletion failed (see details field) |