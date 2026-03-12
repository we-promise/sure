# Design: Category Icon Fix & GET /api/v1/categories/icons Endpoint

**Date:** 2026-03-11
**Branch:** fix/unknown-category-icon

---

## Problem

A production server error was identified in the logs:

```
ActionView::Template::Error (Unknown icon hiking for app/views/categories/_badge.html.erb)
```

A category with `lucide_icon: "hiking"` exists in the database. The `_badge.html.erb` partial guards with `.present?` only, so any non-empty icon string reaches `lucide_icon()` in the `icon` helper, which raises if the icon name isn't in the Lucide gem.

There is no model-level validation preventing arbitrary strings from being saved as `lucide_icon`.

---

## Bug Fix

### 1. Template guard (`app/views/categories/_badge.html.erb`)

Strengthen the guard from presence-only to also check validity:

```erb
<% if category.lucide_icon.present? && Category.icon_codes.include?(category.lucide_icon) %>
```

Unknown icons silently render without an icon — no crash, graceful degradation.

### 2. Model validation (`app/models/category.rb`)

Add an inclusion validation to prevent future saves with invalid icon names:

```ruby
validates :lucide_icon, inclusion: { in: -> (_) { Category.icon_codes } }
```

- Synthetic (non-persisted) categories (`uncategorized`, `other_investments`) are never run through ActiveRecord validations, so they are unaffected.
- Existing DB records with invalid icons can still be read and displayed (template guard handles rendering), but cannot be saved without correcting the icon.

### 3. Tests (Minitest)

In `test/models/category_test.rb`:
- Assert a category with `lucide_icon: "hiking"` fails validation with an inclusion error.
- Assert a category with a valid icon (e.g. `"bike"`) passes validation.

---

## New Endpoint: `GET /api/v1/categories/icons`

### Purpose

Returns the list of available Lucide icon codes that can be used when creating or updating a category. This is global/static metadata — not family-scoped — so it is publicly accessible without authentication.

### Route

Collection action on the existing categories resource:

```ruby
resources :categories, only: [:index, :show, :create, :update] do
  collection do
    get :icons
  end
end
```

### Controller

New `icons` action on `Api::V1::CategoriesController`. Auth before-actions are skipped for this action only:

```ruby
skip_before_action :authenticate_user!, only: [:icons]

def icons
  render json: { icons: Category.icon_codes }
end
```

### Response

```json
{
  "icons": ["ambulance", "apple", "award", "baby", "badge-dollar-sign", "..."]
}
```

- No pagination (static list, ~100 items).
- No Jbuilder view — direct `render json:` is appropriate for this static, non-model response.

### Tests (Minitest)

In `test/controllers/api/v1/categories_controller_test.rb`:
- `GET /api/v1/categories/icons` with no auth credentials → 200 with `icons` array present.
- Response body includes known valid icons (e.g. `"bike"`, `"utensils"`).

### OpenAPI Spec (rswag)

In `spec/requests/api/v1/categories_spec.rb`:
- Document the path `/api/v1/categories/icons`.
- 200 response schema: object with `icons` property (array of strings).
- No security requirement on this path.

---

## Out of Scope

- Adding `"hiking"` to `icon_codes` (intentionally excluded).
- Migrating existing DB records with invalid icons (template guard handles graceful degradation).
- Pagination or filtering of the icons list.
