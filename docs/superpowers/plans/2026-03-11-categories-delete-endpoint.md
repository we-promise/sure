# Categories Delete Endpoint Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `DELETE /api/v1/categories/:id` that blocks deletion when the category or any subcategory has linked transactions, and hard-deletes otherwise.

**Architecture:** A `before_destroy` callback on `Category` enforces the guard and surfaces an error via `self.errors`. The controller calls `@category.destroy` and branches on the return value. Routes, Minitest behavioral tests, and rswag OpenAPI docs are all updated to match.

**Tech Stack:** Ruby on Rails 7, Minitest + fixtures, rswag (OpenAPI docs only)

**Design spec:** `docs/superpowers/specs/2026-03-11-categories-delete-endpoint-design.md`

---

## Chunk 1: Feature branch + Model guard

### Task 0: Fix incomplete `income` fixture

**Files:**
- Modify: `test/fixtures/categories.yml`

The `income` fixture is missing `lucide_icon` and `classification`, both required by model validations. Fix this before writing any tests that use it.

- [ ] **Step 1: Update `test/fixtures/categories.yml`**

Change:
```yaml
income:
  name: Income
  color: "#fd7f6f"
  family: dylan_family
```

To:
```yaml
income:
  name: Income
  classification: income
  color: "#fd7f6f"
  lucide_icon: circle-dollar-sign
  family: dylan_family
```

---

### Task 1: Create feature branch

**Files:** none (git only)

- [ ] **Step 1: Create and switch to a new branch**

```bash
git checkout -b feature/api-categories-delete
```

Expected: `Switched to a new branch 'feature/api-categories-delete'`

---

### Task 2: Add `before_destroy` guard to `Category` model (TDD)

**Files:**
- Modify: `app/models/category.rb`
- Test: (no dedicated model test file — behavioral coverage comes from controller tests in Task 3)

> **Note:** The model guard will be exercised end-to-end through the controller tests. We write the model code first, then verify it in Task 3.

- [ ] **Step 1: Open `app/models/category.rb` and add the callback and private method**

In `app/models/category.rb`, add `before_destroy :prevent_destroy_if_transactions_exist` to the existing callback block (after `before_save :inherit_color_from_parent`), and add the private method at the bottom of the `private` section:

```ruby
# After existing before_save line:
before_destroy :prevent_destroy_if_transactions_exist
```

```ruby
# Inside the existing `private` block, after the last method:
def prevent_destroy_if_transactions_exist
  has_transactions = transactions.exists? ||
    subcategories.any? { |sub| sub.transactions.exists? }

  if has_transactions
    errors.add(:base, "Cannot delete a category that has transactions linked to it")
    throw(:abort)
  end
end
```

- [ ] **Step 2: Verify the file looks correct**

```bash
bin/rails runner "c = Category.first; puts c.class"
```

Expected: `Category` (confirms file loads without syntax errors)

---

## Chunk 2: Routes + Controller

### Task 3: Update routes

**Files:**
- Modify: `config/routes.rb` (line ~384)

- [ ] **Step 1: Find the API categories route**

```bash
grep -n "resources :categories" config/routes.rb
```

Expected output includes the API-namespaced line:
```
384:      resources :categories, only: [ :index, :show, :create, :update ]
```

- [ ] **Step 2: Add `:destroy` to the API categories resource**

Change:
```ruby
resources :categories, only: [ :index, :show, :create, :update ]
```

To:
```ruby
resources :categories, only: [ :index, :show, :create, :update, :destroy ]
```

- [ ] **Step 3: Verify the route is registered**

```bash
bin/rails routes | grep "DELETE.*api/v1/categories"
```

Expected output:
```
DELETE /api/v1/categories/:id(.:format)  api/v1/categories#destroy
```

---

### Task 4: Add `destroy` action to categories controller (TDD)

**Files:**
- Modify: `app/controllers/api/v1/categories_controller.rb`
- Test: `test/controllers/api/v1/categories_controller_test.rb`

#### Step 1 — Write the failing tests first

- [ ] **Step 1: Add destroy tests to the existing test file**

Open `test/controllers/api/v1/categories_controller_test.rb` and append the following block **before the final `end`**:

```ruby
# ── Destroy action tests ───────────────────────────────────────────────────

test "destroy requires authentication" do
  delete "/api/v1/categories/#{@category.id}"
  assert_response :unauthorized

  body = JSON.parse(response.body)
  assert_equal "unauthorized", body["error"]
end

test "destroy requires write scope" do
  delete "/api/v1/categories/#{@category.id}", headers: {
    "Authorization" => "Bearer #{@access_token.token}"
  }
  assert_response :forbidden
end

test "destroy returns 404 for unknown category" do
  delete "/api/v1/categories/00000000-0000-0000-0000-000000000000", headers: {
    "Authorization" => "Bearer #{@write_access_token.token}"
  }
  assert_response :not_found

  body = JSON.parse(response.body)
  assert_equal "not_found", body["error"]
end

test "destroy returns 404 for another family's category" do
  other_category = categories(:one) # belongs to :empty family

  delete "/api/v1/categories/#{other_category.id}", headers: {
    "Authorization" => "Bearer #{@write_access_token.token}"
  }
  assert_response :not_found
end

test "destroy returns 422 when category has transactions" do
  # categories(:food_and_drink) is linked to transactions(:one)
  delete "/api/v1/categories/#{@category.id}", headers: {
    "Authorization" => "Bearer #{@write_access_token.token}"
  }
  assert_response :unprocessable_entity

  body = JSON.parse(response.body)
  assert_equal "category_has_transactions", body["error"]
  assert_match /Cannot delete a category/, body["message"]
end

test "destroy returns 422 when a subcategory has transactions" do
  # Give the subcategory a transaction, then try to delete the parent
  entry = accounts(:depository).entries.create!(
    name: "Sub tx",
    date: Date.today,
    amount: 10,
    currency: "USD",
    entryable: Transaction.new(category: @subcategory)
  )

  # Delete the parent — blocked because subcategory has transactions
  parent = @subcategory.parent
  delete "/api/v1/categories/#{parent.id}", headers: {
    "Authorization" => "Bearer #{@write_access_token.token}"
  }
  assert_response :unprocessable_entity

  body = JSON.parse(response.body)
  assert_equal "category_has_transactions", body["error"]
ensure
  entry&.destroy
end

test "destroy succeeds when category has no transactions" do
  # categories(:income) has no linked transactions
  income = categories(:income)

  assert_difference "Category.count", -1 do
    delete "/api/v1/categories/#{income.id}", headers: {
      "Authorization" => "Bearer #{@write_access_token.token}"
    }
  end

  assert_response :ok
  body = JSON.parse(response.body)
  assert_equal "Category deleted successfully", body["message"]
end

test "destroy nullifies subcategory parent_ids when parent has no transactions" do
  # Create a parent+subcategory pair with no transactions
  parent = @user.family.categories.create!(
    name: "Empty Parent",
    classification: "expense",
    color: "#aabbcc",
    lucide_icon: "shapes"
  )
  child = @user.family.categories.create!(
    name: "Empty Child",
    classification: "expense",
    color: "#aabbcc",
    lucide_icon: "shapes",
    parent: parent
  )

  delete "/api/v1/categories/#{parent.id}", headers: {
    "Authorization" => "Bearer #{@write_access_token.token}"
  }

  assert_response :ok
  child.reload
  assert_nil child.parent_id, "Subcategory should become a root category after parent is deleted"
end
```

- [ ] **Step 2: Run the new tests to confirm they all fail (controller action doesn't exist yet)**

```bash
bin/rails test test/controllers/api/v1/categories_controller_test.rb -n "/destroy/"
```

Expected: failures like `ActionController::RoutingError` or `NoMethodError` for the `destroy` action.

#### Step 2 — Implement the controller action

- [ ] **Step 3: Update `before_action` filters in `app/controllers/api/v1/categories_controller.rb`**

Change:
```ruby
before_action :ensure_write_scope, only: [ :create, :update ]
before_action :set_category, only: [ :show, :update ]
```

To:
```ruby
before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
before_action :set_category, only: [ :show, :update, :destroy ]
```

- [ ] **Step 4: Add the `destroy` action after the `update` action**

```ruby
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
  Rails.logger.error e.backtrace.join("\n")

  render json: {
    error: "internal_server_error",
    message: "Error: #{e.message}"
  }, status: :internal_server_error
end
```

- [ ] **Step 5: Run the destroy tests — all should pass**

```bash
bin/rails test test/controllers/api/v1/categories_controller_test.rb -n "/destroy/"
```

Expected: all tests pass with no failures.

- [ ] **Step 6: Run the full categories controller test suite to ensure no regressions**

```bash
bin/rails test test/controllers/api/v1/categories_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb \
        app/models/category.rb \
        app/controllers/api/v1/categories_controller.rb \
        test/controllers/api/v1/categories_controller_test.rb
git commit -m "feat: add DELETE /api/v1/categories/:id endpoint"
```

---

## Chunk 3: OpenAPI docs + CI checks

### Task 5: Add rswag OpenAPI spec for the delete endpoint

**Files:**
- Modify: `spec/requests/api/v1/categories_spec.rb`

- [ ] **Step 1: Add a `delete` block inside the existing `/api/v1/categories/{id}` path block**

In `spec/requests/api/v1/categories_spec.rb`, find the existing `path '/api/v1/categories/{id}' do` block (around line 139). Inside that block, **after** the closing `end` of the `patch` block but **before** the closing `end` of the `path` block, add:

```ruby
delete 'Delete a category' do
  tags 'Categories'
  security [ { apiKeyAuth: [] } ]
  produces 'application/json'

  let(:id) { income_category.id }

  response '200', 'category deleted' do
    schema '$ref' => '#/components/schemas/DeleteResponse'

    run_test!
  end

  response '404', 'category not found' do
    schema '$ref' => '#/components/schemas/ErrorResponse'

    let(:id) { SecureRandom.uuid }

    run_test!
  end

  response '422', 'category has linked transactions' do
  schema '$ref' => '#/components/schemas/ErrorResponse'

  let(:id) { parent_category.id }

  before do
    # Link a transaction to the category so the guard triggers
    account = family.accounts.create!(
      name: 'Test Account',
      accountable: Depository.new,
      currency: 'USD'
    )
    account.entries.create!(
      name: 'Linked tx',
      date: Date.today,
      amount: 10,
      currency: 'USD',
      entryable: Transaction.new(category: parent_category)
    )
  end

  run_test!
end
```

- [ ] **Step 2: Regenerate the OpenAPI YAML**

```bash
RAILS_ENV=test bundle exec rake rswag:specs:swaggerize
```

Expected: `docs/api/openapi.yaml` is updated with the new DELETE operation. No errors.

- [ ] **Step 3: Commit**

```bash
git add spec/requests/api/v1/categories_spec.rb docs/api/openapi.yaml
git commit -m "docs: add OpenAPI spec for DELETE /api/v1/categories/:id"
```

---

### Task 6: Full CI pre-PR checks

- [ ] **Step 1: Run the full test suite**

```bash
bin/rails test
```

Expected: all tests pass, zero failures.

- [ ] **Step 2: Run Ruby linter with auto-correct**

```bash
bin/rubocop -f github -a
```

Expected: no offenses (or only auto-corrected). If manual corrections are needed, fix them, re-run, then stage and commit any changes:

```bash
git add -p
git commit -m "style: rubocop auto-corrections for categories delete endpoint"
```

- [ ] **Step 3: Run ERB linter**

```bash
bundle exec erb_lint ./app/**/*.erb -a
```

Expected: no issues (no ERB files were changed, but run as required by CLAUDE.md).

- [ ] **Step 4: Run security analysis**

```bash
bin/brakeman --no-pager
```

Expected: no new warnings.

- [ ] **Step 5: All checks pass — ready to open PR**
