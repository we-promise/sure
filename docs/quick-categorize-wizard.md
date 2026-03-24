# Quick Categorize Wizard

## Context

When a user first connects a bank account, many transactions arrive uncategorized. The current path (filter → select → bulk update drawer → repeat) is slow and doesn't support creating auto-categorization rules inline. This feature adds a step-by-step wizard that groups uncategorized transactions, lets the user assign a category to each group, and optionally create a rule — all without leaving the flow.

---

## User Flow

1. Transactions index shows a **"Categorize (N)"** button when uncategorized transactions exist
2. Clicking opens the wizard at `GET /transactions/categorize`
3. Wizard shows **one group at a time**: merchant name/avatar, list of transactions (each deselectable), total amount
4. User clicks a **category pill** to assign (filtered to income or expense based on group type)
5. A searchable text field filters categories as user types; Enter selects the focused one
6. If >1 transaction selected → **"Create rule"** checkbox shown, checked by default
7. If rule checkbox is checked → opens the **existing rule editor modal** pre-filled (same pattern as the category CTA today)
8. "Skip" advances to position+1 without categorizing; that group may reappear next session
9. "Exit" returns to `transactions_path` at any time
10. When position ≥ total groups → redirect to `transactions_path` with a summary notice

---

## Grouping Architecture

Grouping is encapsulated behind an abstraction so the algorithm can be improved independently.

### `Transaction::Grouper` (abstract interface)
**File:** `app/models/transaction/grouper.rb`

- Defines a `Group` value object (`Data.define`): `grouping_key`, `display_name`, `transactions`, `merchant`
- Exposes a `STRATEGY` constant pointing to the active implementation
- Subclasses implement `self.call(family, limit:, offset:)`

### `Transaction::Grouper::ByMerchantOrName` (v1 implementation)
**File:** `app/models/transaction/grouper/by_merchant_or_name.rb`

- Queries `family.transactions` where `category_id IS NULL` and `kind NOT IN TRANSFER_KINDS`, includes `entry`, `merchant`
- Groups in Ruby: key = `merchant.name` if present, else `entry.name`
- Sorts by `[-transactions.count, grouping_key]`
- Respects `limit` and `offset` for pagination
- Returns array of `Group` value objects

The `limit`/`offset` approach works naturally: as transactions get categorized they drop out of the uncategorized pool, so the list self-updates on each request. Future implementations could use PostgreSQL `pg_trgm` similarity or normalized name stemming without touching the wizard UI.

---

## Routes

Add inside the existing `namespace :transactions` block in `config/routes.rb`:

```ruby
namespace :transactions do
  resource :bulk_deletion, only: :create
  resource :bulk_update,   only: %i[new create]
  resource :categorize,    only: %i[show create]   # NEW
end
```

Yields:
- `GET  /transactions/categorize?position=N` → wizard step
- `POST /transactions/categorize` → apply categorization for current group

---

## Controller

**File:** `app/controllers/transactions/categorizes_controller.rb`

- `show`: computes `@group` at current position, `@categories` filtered by group type (income/expense)
- `create`: calls `Entry.bulk_update!` on selected entries, then either redirects to `new_rule_path` (pre-filled) or back to wizard at same position
- State is entirely in query params (`position`) and form fields — no session needed
- Skip = redirect to `position + 1`
- Categorize = redirect to same `position` (the processed group drops out naturally)

### Category filtering
- All amounts positive → `family.categories.expenses`
- All amounts negative → `family.categories.incomes`
- Mixed (rare) → `family.categories.all`

---

## Rule Editor Integration

After categorizing with "Create rule" checked, redirect to the existing `new_rule_path` with pre-filled params:

```
new_rule_path(
  resource_type: "transaction",
  name:          grouping_key,
  action_type:   "set_transaction_category",
  action_value:  category_id,
  return_to:     transactions_categorize_path(position: position)
)
```

`RulesController` already supports `name`, `action_type`, `action_value` pre-fill. One addition needed:
- Support a `return_to` param in `new`/`create` to redirect back to the wizard instead of `rules_path`
- Validate `return_to` is an internal path (use Rails `url_from` helper)

---

## Views

### Wizard step (`app/views/transactions/categorizes/show.html.erb`)

```
[Exit]                                   [N groups remaining]

[Merchant avatar]  Group name
                   X transactions · $total

  [✓] Transaction name 1    $12.50   Jan 3
  [✓] Transaction name 2    $8.00    Jan 5
  ...

── Assign a category ────────────────────────────────────
  [Search categories...]

  [Food & Drink] [Groceries] [Shopping] [Transport] ...
  (scrollable pill grid, filtered by income/expense type)

  [✓ Create auto-categorization rule]   (if >1 tx selected)

[Skip]                                            [Exit]
```

- Checkboxes on each transaction row (all checked by default)
- Category pills submit the form with `category_id` set
- Text field uses existing `list-filter` Stimulus controller to filter pills
- "Create rule" checkbox checked by default when group has >1 transaction

### Entry point (`app/views/transactions/_categorize_button.html.erb`)
Button partial rendered in the transactions index header.

---

## Transactions Index Changes

### `app/controllers/transactions_controller.rb` — `index` action
Add `@uncategorized_count` query (scoped to active accounts, excluding transfers).

### `app/views/transactions/index.html.erb`
Add button to existing header button group, visible only when `@uncategorized_count > 0`:
```erb
<% if @uncategorized_count > 0 %>
  <%= render DS::Link.new(
    text: t(".categorize_button", count: @uncategorized_count),
    icon: "tag",
    variant: "outline",
    href: transactions_categorize_path
  ) %>
<% end %>
```

---

## i18n Keys (`config/locales/en.yml`)

```yaml
en:
  transactions:
    index:
      categorize_button:
        one:   "Categorize (1)"
        other: "Categorize (%{count})"
    categorizes:
      show:
        title:              "Categorize Transactions"
        remaining:
          one:   "1 group remaining"
          other: "%{count} groups remaining"
        exit:               "Exit"
        skip:               "Skip"
        assign_category:    "Assign a category"
        filter_placeholder: "Search categories..."
        create_rule_label:  "Create auto-categorization rule"
        all_done:           "All transactions are categorized"
      create:
        categorized:
          one:   "1 transaction categorized"
          other: "%{count} transactions categorized"
```

---

## Edge Cases

| Scenario | Handling |
|---|---|
| No uncategorized transactions | Button hidden; `show` redirects with notice |
| Transfers / cc payments | Excluded via `TRANSFER_KINDS` in grouper scope |
| User deselects all transactions | Validate `entry_ids` present before submitting |
| Mixed income/expense in one group | Show all categories |
| `return_to` param tampered | Validate with `url_from` helper; fall back to `rules_path` |
| Position past end of groups | Redirect to `transactions_path` with "all done" notice |

---

## Files to Create

| File | Purpose |
|---|---|
| `app/models/transaction/grouper.rb` | Abstract grouper + `Group` value object + `STRATEGY` constant |
| `app/models/transaction/grouper/by_merchant_or_name.rb` | V1 grouping implementation |
| `app/controllers/transactions/categorizes_controller.rb` | Wizard controller |
| `app/views/transactions/categorizes/show.html.erb` | Wizard step view |
| `app/views/transactions/_categorize_button.html.erb` | Button partial for index |

## Files to Modify

| File | Change |
|---|---|
| `config/routes.rb` | Add `resource :categorize` to `namespace :transactions` |
| `app/controllers/transactions_controller.rb` | Add `@uncategorized_count` to `index` |
| `app/views/transactions/index.html.erb` | Add categorize button to header |
| `app/controllers/rules_controller.rb` | Support `return_to` param in `new`/`create` |
| `config/locales/en.yml` | Add i18n keys |

---

## Tests

### `test/models/transaction/grouper/by_merchant_or_name_test.rb`
- Groups by merchant when present
- Falls back to entry name when no merchant
- Excludes transfers
- Excludes already-categorized transactions
- Respects limit/offset

### `test/controllers/transactions/categorizes_controller_test.rb`
- `GET show` renders first group when uncategorized exist
- `GET show` redirects when nothing to categorize
- `GET show?position=1` shows second group
- `POST create` bulk-categorizes selected entries and redirects to same position
- `POST create` with `create_rule=1` redirects to rule editor with pre-filled params
- `POST create` requires authentication

### `test/controllers/rules_controller_test.rb`
- `POST create` with valid `return_to` redirects there after success
- `POST create` with invalid `return_to` falls back to `rules_path`

---

## Implementation Order

1. `config/routes.rb` — add route
2. `app/models/transaction/grouper.rb` + `by_merchant_or_name.rb` — grouping logic
3. `app/controllers/transactions/categorizes_controller.rb` — wizard controller
4. `app/views/transactions/categorizes/show.html.erb` — wizard view
5. `app/controllers/transactions_controller.rb` — add `@uncategorized_count`
6. `app/views/transactions/index.html.erb` + `_categorize_button.html.erb` — entry point
7. `app/controllers/rules_controller.rb` — add `return_to` support
8. `config/locales/en.yml` — i18n keys
9. Tests
