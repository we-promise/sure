# Categories API Documentation

The Categories API allows external applications to retrieve and create financial categories within Sure. Categories are used to classify transactions and can be organized in a hierarchical structure with parent categories and subcategories. The OpenAPI description is generated directly from executable request specs, ensuring it always reflects the behaviour of the running Rails application.

## Generated OpenAPI specification

- The source of truth for the documentation lives in [`spec/requests/api/v1/categories_spec.rb`](../../spec/requests/api/v1/categories_spec.rb). These specs authenticate against the Rails stack, exercise every category endpoint, and capture real response shapes.
- Regenerate the OpenAPI document with:

  ```sh
  RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
  ```

  The task compiles the request specs and writes the result to [`docs/api/openapi.yaml`](openapi.yaml).

- Run just the documentation specs with:

  ```sh
  bundle exec rspec spec/requests/api/v1/categories_spec.rb
  ```

## Authentication requirements

All category endpoints require an OAuth2 access token or API key. Read endpoints accept the `read` scope; creating a category requires the `read_write` scope.

## Available endpoints

| Endpoint | Scope | Description |
| --- | --- | --- |
| `GET /api/v1/categories` | `read` | List categories with filtering and pagination. |
| `GET /api/v1/categories/{id}` | `read` | Retrieve a single category with full details. |
| `POST /api/v1/categories` | `read_write` | Create a new category. |

There are no update or delete endpoints. Categories can only be edited or removed through the web UI.

Refer to the generated [`openapi.yaml`](openapi.yaml) for request/response schemas, reusable components (pagination, errors), and security definitions.

## Filtering options

The `GET /api/v1/categories` endpoint supports the following query parameters for filtering:

| Parameter | Type | Description |
| --- | --- | --- |
| `page` | integer | Page number (default: 1) |
| `per_page` | integer | Items per page (default: 25, max: 100) |
| `roots_only` | boolean | Return only root categories (categories without a parent) |
| `parent_id` | uuid | Filter subcategories by parent category ID |

## Category object

A category response includes:

```json
{
  "id": "uuid",
  "name": "Food & Drink",
  "color": "#f97316",
  "icon": "utensils",
  "parent": null,
  "subcategories_count": 2,
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

## Category hierarchy

Categories support a two-level hierarchy:

- **Root categories** (parent categories) have `parent: null` and may have subcategories
- **Subcategories** have a `parent` object containing the parent's `id` and `name`

Example subcategory response:

```json
{
  "id": "uuid",
  "name": "Restaurants",
  "color": "#f97316",
  "icon": "utensils",
  "parent": {
    "id": "uuid",
    "name": "Food & Drink"
  },
  "subcategories_count": 0,
  "created_at": "2024-01-15T10:30:00Z",
  "updated_at": "2024-01-15T10:30:00Z"
}
```

## Creating categories

`POST /api/v1/categories` accepts the following attributes under a `category` key:

| Attribute | Type | Description |
| --- | --- | --- |
| `name` | string | **Required.** Category name. |
| `color` | string | Hex colour, e.g. `#f97316`. |
| `icon` | string | Lucide icon name. Stored as `lucide_icon`; when omitted, an icon is suggested from the name. |
| `parent_id` | uuid | Parent category, to create a subcategory. Must belong to your family. |

Example request body:

```json
{
  "category": {
    "name": "Restaurants",
    "color": "#f97316",
    "icon": "utensils",
    "parent_id": "<parent-category-uuid>"
  }
}
```

A successful request returns `201 Created` with the same object shape described above. A `parent_id` that does not belong to your family returns `422 Unprocessable Entity`.

## Filtering examples

### Get only root categories (no subcategories)

```
GET /api/v1/categories?roots_only=true
```

### Get subcategories of a specific parent

```
GET /api/v1/categories?parent_id=<parent-category-uuid>
```

### Combine filters with pagination

```
GET /api/v1/categories?roots_only=true&page=1&per_page=10
```

## Error responses

Errors conform to the shared `ErrorResponse` schema in the OpenAPI document:

```json
{
  "error": "error_code",
  "message": "Human readable error message"
}
```

Common error codes include `unauthorized`, `insufficient_scope`, `not_found`, `unprocessable_entity`, and `internal_server_error`.
