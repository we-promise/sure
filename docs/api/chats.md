# Chat API Documentation

The Chat API allows external applications to interact with Sure's AI chat functionality. The OpenAPI description is generated directly from executable request specs, ensuring it always reflects the behaviour of the running Rails application.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/chats_spec.rb`](../../spec/requests/api/v1/chats_spec.rb). These specs authenticate against the Rails stack, exercise every chat endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/chats_spec.rb
  ```

## Authentication requirements

All chat endpoints require an OAuth2 access token or API key that grants the appropriate scope. The authenticated user must also have AI features enabled (`ai_enabled: true`).

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/chats` | `read` | List chats for the authenticated user with pagination metadata. |
| `GET /api/v1/chats/{id}` | `read` | Retrieve a chat, including ordered messages and optional pagination. |
| `POST /api/v1/chats` | `write` | Create a chat and optionally seed it with an initial user message. |
| `PATCH /api/v1/chats/{id}` | `write` | Update a chat title. |
| `DELETE /api/v1/chats/{id}` | `write` | Permanently delete a chat. |
| `POST /api/v1/chats/{chat_id}/messages` | `write` | Append a user message to a chat. |
| `POST /api/v1/chats/{chat_id}/messages/retry` | `write` | Retry the last assistant response in a chat. |

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (pagination, errors, messages, tool calls), and security definitions.

## AI response behaviour

- Chat creation and message submission queue AI processing jobs asynchronously; the API responds immediately with the user message payload.
- Poll `GET /api/v1/chats/{id}` to detect new assistant messages (`type: "assistant_message"`).
- Supported models today: `gpt-4` (default), `gpt-4-turbo`, and `gpt-3.5-turbo`.
- Assistant responses may include structured tool calls (`tool_calls`) that reference financial data fetches and their results.

## Error responses

Errors conform to the shared `ErrorResponse` schema in the OpenAPI document:

```json
{
  "error": "error_code",
  "message": "Human readable error message",
  "details": ["Optional array of extra context"]
}
```

Common error codes include `unauthorized`, `forbidden`, `feature_disabled`, `not_found`, `unprocessable_entity`, and `rate_limit_exceeded`.