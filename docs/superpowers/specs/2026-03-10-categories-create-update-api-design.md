# Categories API — Create & Update Endpoints

**Date:** 2026-03-10
**Status:** Approved

---

## Summary

Add `POST /api/v1/categories` and `PATCH /api/v1/categories/:id` to the existing categories API. Follows the same patterns as the transactions controller for auth, serialization, and error handling.

---

## Routes

Extend the existing `resources :categories` block in the `api/v1` namespace:

```ruby
resources :categories, only: [:index, :show, :create, :update]
```

---

## Controller

File: `app/controllers/api/v1/categories_controller.rb`

- Add `before_action :ensure_write_scope, only: [:create, :update]`
- Add `before_action :set_category, only: [:show, :update]` — scoped to `Current.family.categories`

### `create` (POST /api/v1/categories)

**Required params:** `name`, `classification` ("income" or "expense")
**Optional params:** `color` (hex string), `icon` (mapped to `lucide_icon`), `parent_id`

Flow:
1. If `parent_id` present: validate it resolves to a family-owned root category
   - Not found in family → 422 `"Parent category not found"`
   - Is a subcategory (has its own `parent_id`) → 422 `"Parent must be a root category"`
2. Build category on `Current.family.categories`
3. On success → render `_category.json.jbuilder` partial with status 201
4. On failure → render `{ error: { message: errors.full_messages.to_sentence } }` with status 422

### `update` (PATCH /api/v1/categories/:id)

**All params optional:** `name`, `classification`, `color`, `icon` (mapped to `lucide_icon`), `parent_id`

Flow:
1. `set_category` finds by id scoped to family → 404 if not found (handled by base controller)
2. If `parent_id` present in params: same parent validation as create
3. On success → render `_category.json.jbuilder` partial with status 200
4. On failure → render 422 with errors

---

## Serialization

Reuse the existing `app/views/api/v1/categories/_category.json.jbuilder` partial. No new view files.

Response shape:
```json
{
  "id": "...",
  "name": "Groceries",
  "classification": "expense",
  "color": "#6172F3",
  "icon": "shopping-cart",
  "parent": null,
  "subcategories_count": 0,
  "created_at": "...",
  "updated_at": "..."
}
```

---

## OpenAPI Schemas

Add to `spec/swagger_helper.rb`:
- `CreateCategoryRequest`: name (required), classification (required), color, icon, parent_id (all optional beyond required)
- `UpdateCategoryRequest`: all optional — name, classification, color, icon, parent_id

---

## Tests

### Minitest (`test/controllers/api/v1/categories_controller_test.rb`)

**create:**
- Returns 201 with valid params (no parent)
- Returns 201 with valid parent_id (creates subcategory)
- Returns 401 without auth token
- Returns 403 with read-only scope
- Returns 422 when name missing
- Returns 422 when classification invalid
- Returns 422 when parent_id not found in family
- Returns 422 when parent_id references a subcategory
- Family isolation: cannot use another family's category as parent

**update:**
- Returns 200 with valid params
- Returns 200 updating only name (partial update)
- Returns 401 without auth token
- Returns 403 with read-only scope
- Returns 404 for unknown id
- Returns 404 for another family's category id
- Returns 422 when parent_id references a subcategory
- Returns 422 when classification set to invalid value

### rswag (`spec/requests/api/v1/categories_spec.rb`)

Add `POST /api/v1/categories` and `PATCH /api/v1/categories/{id}` paths using `run_test!` only (docs generation, no assertions).

---

## Key Constraints

- `icon` in the API maps to `lucide_icon` in the database — controller handles this translation
- Color and icon default via DB/model when not provided (`#6172F3` and `shapes`)
- All queries scoped to `Current.family` — no cross-family data access possible
- 2-level hierarchy enforced at API layer with explicit 422 errors
