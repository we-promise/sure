# Tags API

The Tags API allows external applications to manage tags within Sure. Tags provide a flexible way to categorize and label transactions beyond the standard category system.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/tags_spec.rb`](../../spec/requests/api/v1/tags_spec.rb). These specs authenticate against the Rails stack, exercise every tag endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  SWAGGER_DRY_RUN=0 bundle exec rspec spec/requests --format Rswag::Specs::SwaggerFormatter
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/tags_spec.rb
  ```

## Authentication requirements

| Operation | Scope Required |
| --- | --- |
| List/View tags | `read` |
| Create/Update/Delete tags | `write` |

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/tags` | `read` | List all tags belonging to the family. |
| `GET /api/v1/tags/{id}` | `read` | Retrieve a single tag by ID. |
| `POST /api/v1/tags` | `write` | Create a new tag. |
| `PATCH /api/v1/tags/{id}` | `write` | Update an existing tag. |
| `DELETE /api/v1/tags/{id}` | `write` | Permanently delete a tag. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components, and security definitions.

## Tag object

A tag response includes:

```json
{
  "id": "uuid",
  "name": "Essential",
  "color": "#3b82f6",
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

## Available colors

Sure provides a predefined set of colors for tags. If no color is specified when creating a tag, one will be randomly assigned from this palette:

```text
#e99537, #4da568, #6471eb, #db5a54, #df4e92,
#c44fe9, #eb5429, #61c9ea, #805dee, #6b7c93
```

## Creating tags

Example request:

```http
POST /api/v1/tags
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "tag": {
    "name": "Business",
    "color": "#6471eb"
  }
}
```

The `color` field is optional. If omitted, a random color from the predefined palette will be assigned.

Example response (201 Created):

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440001",
  "name": "Business",
  "color": "#6471eb",
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

## Updating tags

Example request:

```http
PATCH /api/v1/tags/550e8400-e29b-41d4-a716-446655440001
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "tag": {
    "name": "Work Expenses",
    "color": "#4da568"
  }
}
```

Both `name` and `color` are optional in update requests.

## Deleting tags

Example request:

```http
DELETE /api/v1/tags/550e8400-e29b-41d4-a716-446655440001
Authorization: Bearer <access_token>
```

Returns `204 No Content` on success.

## Using tags with transactions

Tags can be assigned to transactions using the `tag_ids` array field. A transaction can have multiple tags:

```json
{
  "transaction": {
    "account_id": "uuid",
    "date": "2024-01-15",
    "amount": 150.00,
    "name": "Team lunch",
    "nature": "expense",
    "tag_ids": [
      "550e8400-e29b-41d4-a716-446655440001",
      "550e8400-e29b-41d4-a716-446655440002"
    ]
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

Common error codes include:

| Status | Error | Description |
| --- | --- | --- |
| 401 | `unauthorized` | Invalid or missing access token. |
| 404 | `not_found` | Tag not found or does not belong to the family. |
| 422 | `validation_failed` | Invalid input (e.g., duplicate name, missing required field). |
| 500 | `internal_server_error` | Unexpected server error. |
