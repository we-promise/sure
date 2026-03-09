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

All user endpoints require an OAuth2 access token or API key that grants the `write` scope.

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `DELETE /api/v1/users/reset` | `write` | Reset account data while preserving the user account. |
| `DELETE /api/v1/users/me` | `write` | Permanently delete the user account. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (errors), and security definitions.

## Reset account

`DELETE /api/v1/users/reset`

Resets all financial data (accounts, categories, merchants, tags, transactions, etc.) for the current user's family while keeping the user account intact. The reset runs asynchronously in the background.

### Request

No request body required.

### Response

```json
{
  "message": "Account reset has been initiated"
}
```

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

In addition to standard error codes (`unauthorized`, `forbidden`), the delete endpoint may return:

**422 Unprocessable Entity**

```json
{
  "error": "Failed to delete account",
  "details": ["Cannot deactivate admin with other users"]
}
```

This occurs when the user cannot be deactivated (for example, an admin user with other active users in the family).

## Security considerations

- Both endpoints require the `write` scope. Read-only API keys cannot access these endpoints.
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
| `forbidden` | API key lacks required `write` scope |
| `unprocessable_entity` | Account deletion failed (see details field) |
