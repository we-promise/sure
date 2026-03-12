# Design: DELETE /api/v1/categories/:id

**Date:** 2026-03-11
**Status:** Approved

## Overview

Add a delete endpoint for categories in the external API. Deletion is blocked if the category or any of its subcategories has transactions linked to it.

## Route

```ruby
resources :categories, only: [ :index, :show, :create, :update, :destroy ]
```

- `DELETE /api/v1/categories/:id`
- Requires write scope (`read_write`)
- Scoped to the current family (cross-family deletion returns 404)

## Model — `before_destroy` Callback

Add a private callback to `Category` that checks the category itself and all subcategories for linked transactions. If any exist, abort the destroy and add an error.

```ruby
before_destroy :prevent_destroy_if_transactions_exist

private

def prevent_destroy_if_transactions_exist
  has_transactions = transactions.exists? ||
    subcategories.any? { |sub| sub.transactions.exists? }

  if has_transactions
    errors.add(:base, "Cannot delete a category that has transactions linked to it")
    throw(:abort)
  end
end
```

When no transactions exist, the existing `dependent: :nullify` on subcategories runs normally — subcategories become root-level categories.

## Controller — `destroy` Action

Extend existing `before_action` filters and add the action following the established create/update pattern.

```ruby
before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
before_action :set_category, only: [ :show, :update, :destroy ]

def destroy
  if @category.destroy
    render json: { message: "Category deleted successfully" }, status: :ok
  else
    render json: {
      error: "category_has_transactions",
      message: @category.errors.full_messages.to_sentence
    }, status: :unprocessable_entity
  end
rescue => e
  Rails.logger.error "CategoriesController#destroy error: #{e.message}"
  render json: { error: "internal_server_error", message: "Error: #{e.message}" },
         status: :internal_server_error
end
```

## Response Format

| Status | Scenario |
|--------|----------|
| 200 | Category deleted successfully |
| 401 | Unauthenticated |
| 403 | Insufficient scope (read-only) |
| 404 | Category not found or belongs to another family |
| 422 | Category or subcategory has linked transactions |
| 500 | Unexpected server error |

Success body:
```json
{ "message": "Category deleted successfully" }
```

Error body (422):
```json
{
  "error": "category_has_transactions",
  "message": "Cannot delete a category that has transactions linked to it"
}
```

## Tests

### Minitest (`test/controllers/api/v1/categories_controller_test.rb`)

- `destroy requires authentication` → 401
- `destroy requires write scope` → 403
- `destroy returns 404 for unknown category` → 404
- `destroy returns 404 for another family's category` → 404
- `destroy succeeds when category has no transactions` → 200, `Category.count` -1
- `destroy returns 422 when category has transactions` → 422, `error: "category_has_transactions"`
- `destroy returns 422 when a subcategory has transactions` → 422
- `destroy nullifies subcategory parent_ids when no transactions` → subcategories become root-level

### rswag OpenAPI (`spec/requests/api/v1/categories_spec.rb`)

New `delete` block under `/api/v1/categories/{id}` with `run_test!` for:
- `200` category deleted
- `404` category not found
- `422` category has transactions
