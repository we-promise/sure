# YNAB → Sure Migration Plan

## Context

Users migrating from YNAB (You Need A Budget) need a way to bring their financial data into Sure. This plan maps every YNAB API entity to its Sure equivalent, identifies missing Sure API endpoints, and defines the migration order. The migration script will **read from YNAB's API** (`GET` endpoints) and **write to Sure's API** (`POST`/`PATCH` endpoints).

YNAB uses "plans" (formerly "budgets") as the top-level entity. Amounts are in **milliunits** (divide by 1000 to get dollars). Sure uses "families" as the top-level entity with decimal amounts.

---

## 1. Entity Mapping: YNAB → Sure

| YNAB Entity | Sure Entity | Relationship | Notes |
|---|---|---|---|
| Plan (Budget) | Family | 1:1 | Family already exists for the authenticated user; no creation needed |
| Account | Account + Accountable | 1:1 | Type mapping required (see below) |
| CategoryGroup | Category (parent) | 1:1 | Sure uses parent categories as the equivalent of YNAB category groups |
| Category | Category (child) | 1:1 | Child of the parent category that maps to its CategoryGroup |
| Payee | Merchant (FamilyMerchant) | 1:1 | YNAB payees become Sure family merchants |
| Transaction | Entry + Transaction | 1:1 | Entry holds date/amount/name; Transaction holds category/merchant/tags |
| SubTransaction | Entry (child) + Transaction | 1:many | Sure supports split transactions via `parent_entry_id` |
| Transfer (via `transfer_account_id`) | Transfer | 1:1 | Two paired transactions linked by a Transfer record |
| Scheduled Transaction | RecurringTransaction | 1:1 | Partial mapping — Sure's model is pattern-based, not schedule-based |
| Month (budget month) | Budget | 1:1 | Monthly budget with income/spending targets |
| Month Category (budget allocation) | BudgetCategory | 1:1 | Per-category budget amount for a given month |
| Payee Location | *(no equivalent)* | — | Sure doesn't track merchant locations; skip |
| Flag Color | *(no equivalent)* | — | Could map to Tags as a workaround |
| Cleared/Reconciled status | *(no equivalent)* | — | Sure doesn't track cleared status; skip |
| Goal (on Category) | *(no equivalent)* | — | Sure budgets don't have goal types; skip |

### Account Type Mapping

| YNAB Account Type | Sure Accountable Type | Sure Subtype |
|---|---|---|
| `checking` | `Depository` | `checking` |
| `savings` | `Depository` | `savings` |
| `cash` | `Depository` | `checking` |
| `creditCard` | `CreditCard` | `credit_card` |
| `lineOfCredit` | `CreditCard` | `credit_card` |
| `mortgage` | `Loan` | `mortgage` |
| `autoLoan` | `Loan` | `auto` |
| `studentLoan` | `Loan` | `student` |
| `personalLoan` | `Loan` | `other` |
| `medicalDebt` | `OtherLiability` | — |
| `otherDebt` | `OtherLiability` | — |
| `otherAsset` | `OtherAsset` | — |
| `otherLiability` | `OtherLiability` | — |

---

## 2. API Endpoint Mapping: YNAB Read → Sure Write

### Phase 1: Categories (must exist before transactions)

| Step | YNAB Source (Read) | Sure Destination (Write) | Status |
|---|---|---|---|
| 1a | `GET /plans/{id}/categories` → extract `category_groups` | `POST /api/v1/categories` (create parent categories) | **MISSING** |
| 1b | `GET /plans/{id}/categories` → extract `categories` within groups | `POST /api/v1/categories` (create child categories with `parent_id`) | **MISSING** |

### Phase 2: Accounts (must exist before transactions)

| Step | YNAB Source (Read) | Sure Destination (Write) | Status |
|---|---|---|---|
| 2a | `GET /plans/{id}/accounts` | `POST /api/v1/accounts` (create with type mapping) | **MISSING** |
| 2b | For each account with `balance` | `POST /api/v1/valuations` (set opening balance) | EXISTS |

### Phase 3: Merchants/Payees (must exist before transactions)

| Step | YNAB Source (Read) | Sure Destination (Write) | Status |
|---|---|---|---|
| 3 | `GET /plans/{id}/payees` | `POST /api/v1/merchants` (create FamilyMerchant) | **MISSING** |

### Phase 4: Transactions (bulk migration)

| Step | YNAB Source (Read) | Sure Destination (Write) | Status |
|---|---|---|---|
| 4a | `GET /plans/{id}/transactions` (all non-transfer txns) | `POST /api/v1/transactions` (one per transaction) | EXISTS |
| 4b | Transactions with `subtransactions` | `POST /api/v1/transactions` (parent) + child entries | **PARTIAL** — need split transaction support in API |
| 4c | Transactions with `transfer_account_id` | Create both sides, then link via transfer | **MISSING** — no transfer creation API |

### Phase 5: Budgets (monthly allocations)

| Step | YNAB Source (Read) | Sure Destination (Write) | Status |
|---|---|---|---|
| 5a | `GET /plans/{id}/months` | `POST /api/v1/budgets` (create monthly budget) | **MISSING** |
| 5b | `GET /plans/{id}/months/{month}/categories/{id}` | `POST /api/v1/budget_categories` (set category allocation) | **MISSING** |

### Phase 6: Scheduled/Recurring Transactions

| Step | YNAB Source (Read) | Sure Destination (Write) | Status |
|---|---|---|---|
| 6 | `GET /plans/{id}/scheduled_transactions` | `POST /api/v1/recurring_transactions` | **MISSING** |

---

## 3. Missing Sure API Endpoints (Must Build)

### Priority 1 — Required for basic migration

| # | Endpoint | Method | Controller Action | Notes |
|---|---|---|---|---|
| 1 | `/api/v1/accounts` | `POST` | `AccountsController#create` | Create account with accountable type/subtype, name, currency, balance. Must create the polymorphic accountable record (Depository, CreditCard, Loan, etc.) |
| 2 | `/api/v1/categories` | `POST` | `CategoriesController#create` | Create category with name, color, icon, optional `parent_id`. Controller exists but only has `index`/`show` |
| 3 | `/api/v1/merchants` | `POST` | `MerchantsController#create` | Create FamilyMerchant with name. Controller exists but only has `index`/`show` |

### Priority 2 — Required for full-fidelity migration

| # | Endpoint | Method | Controller Action | Notes |
|---|---|---|---|---|
| 4 | `/api/v1/budgets` | `POST` | `BudgetsController#create` | Create budget with `start_date`, `end_date`, `budgeted_spending`, `expected_income` |
| 5 | `/api/v1/budgets/{id}/budget_categories` | `POST` | `BudgetCategoriesController#create` | Set per-category budget allocation: `category_id`, `budgeted_spending` |
| 6 | `/api/v1/budgets/{id}/budget_categories/{id}` | `PATCH` | `BudgetCategoriesController#update` | Update allocation amount |
| 7 | `/api/v1/transfers` | `POST` | `TransfersController#create` | Link two existing transaction entries as a transfer: `inflow_transaction_id`, `outflow_transaction_id` |
| 8 | `/api/v1/recurring_transactions` | `POST` | `RecurringTransactionsController#create` | Create with `name`, `amount`, `currency`, `expected_day_of_month`, `merchant_id`, `status` |

### Priority 3 — Nice-to-have for migration UX

| # | Endpoint | Method | Controller Action | Notes |
|---|---|---|---|---|
| 9 | `/api/v1/transactions` (bulk) | `POST` | `TransactionsController#bulk_create` | Accept array of transactions for performance. Current API only creates one at a time |
| 10 | `/api/v1/accounts` | `PATCH` | `AccountsController#update` | Update account name/notes after creation |

---

## 4. Data Transformation Rules

### Amounts
- **YNAB → Sure**: Divide by 1000 (`amount_sure = ynab_amount / 1000.0`)
- **Sign convention**: YNAB uses negative for outflows, positive for inflows. Sure uses positive for expenses (outflows), negative for income (inflows). **Negate the converted amount**.
- Formula: `sure_amount = -(ynab_milliunits / 1000.0)`

### Dates
- YNAB: ISO 8601 date strings (`"2024-01-15"`)
- Sure: Same format — no conversion needed

### IDs
- Maintain a **YNAB ID → Sure ID mapping table** during migration for:
  - Accounts (needed for transaction `account_id`)
  - Categories (needed for transaction `category_id`)
  - Payees/Merchants (needed for transaction `merchant_id`)
  - Transactions (needed for transfer linking)
- Use `external_id` field on Entry to store YNAB transaction IDs for deduplication on re-runs

### Currency
- YNAB stores currency format at the plan level (`currency_format.iso_code`)
- Set as the account's `currency` in Sure (or use family default)

### Deleted Records
- YNAB includes a `deleted: true` flag on soft-deleted records
- **Skip** all records where `deleted == true`

### Closed Accounts
- YNAB: `closed: true`
- Sure: Map to `status: "disabled"`

### Transfers
- YNAB identifies transfers via `transfer_account_id` on a transaction
- Each YNAB transfer creates TWO transactions (one in each account) linked by `transfer_transaction_id`
- In Sure: Create both Entry+Transaction records, then POST to `/api/v1/transfers` to link them
- Skip the YNAB "Transfer: Account Name" payee (don't create a merchant for it)

### Split Transactions (SubTransactions)
- YNAB: Parent transaction with `subtransactions` array
- Sure: Parent Entry with child Entries via `parent_entry_id`
- Create parent first, then children referencing parent

### Scheduled → Recurring Transactions
- YNAB has explicit schedule frequencies (daily, weekly, monthly, yearly, etc.)
- Sure's `RecurringTransaction` is pattern-based with `expected_day_of_month`
- Map only monthly-ish frequencies cleanly; others may need approximation
- Set `manual: true` on created recurring transactions

---

## 5. Migration Script Architecture

The migration should be a **standalone script** (or Rake task) that:

1. Authenticates with both APIs (YNAB personal access token + Sure API key)
2. Reads all data from YNAB in dependency order
3. Writes to Sure API in dependency order
4. Maintains ID mapping for cross-references
5. Is **idempotent** — uses `external_id` to skip already-migrated records on re-run
6. Logs progress and errors

### Suggested implementation: `lib/tasks/ynab_migrate.rake`

```
rake ynab:migrate YNAB_TOKEN=xxx SURE_API_KEY=xxx YNAB_PLAN_ID=xxx SURE_API_URL=https://...
```

---

## 6. Implementation Order for New Endpoints

Build in this order (each step unblocks the next):

1. **`POST /api/v1/accounts`** — Extend `AccountsController` with `create` action. Handle accountable type creation. Add route.
2. **`POST /api/v1/categories`** — Extend `CategoriesController` with `create` action. Support `parent_id`. Add route.
3. **`POST /api/v1/merchants`** — Extend `MerchantsController` with `create` action for `FamilyMerchant`. Add route.
4. **`POST /api/v1/transfers`** — New `TransfersController` with `create` action. Add route.
5. **`POST /api/v1/budgets`** + **budget_categories** — New `BudgetsController` and `BudgetCategoriesController`. Add routes.
6. **`POST /api/v1/recurring_transactions`** — New `RecurringTransactionsController`. Add route.
7. **Migration Rake task** — `lib/tasks/ynab_migrate.rake` that orchestrates the full migration.

---

## 7. Files to Create/Modify

### New files:
- `app/controllers/api/v1/budgets_controller.rb`
- `app/controllers/api/v1/budget_categories_controller.rb`
- `app/controllers/api/v1/transfers_controller.rb`
- `app/controllers/api/v1/recurring_transactions_controller.rb`
- `app/views/api/v1/budgets/` (jbuilder templates)
- `app/views/api/v1/budget_categories/` (jbuilder templates)
- `app/views/api/v1/transfers/` (jbuilder templates)
- `app/views/api/v1/recurring_transactions/` (jbuilder templates)
- `lib/tasks/ynab_migrate.rake`
- `spec/requests/api/v1/budgets_spec.rb` (OpenAPI docs)
- `spec/requests/api/v1/transfers_spec.rb` (OpenAPI docs)
- `spec/requests/api/v1/recurring_transactions_spec.rb` (OpenAPI docs)
- `test/controllers/api/v1/accounts_controller_test.rb` (update with create tests)
- `test/controllers/api/v1/categories_controller_test.rb` (update with create tests)
- `test/controllers/api/v1/merchants_controller_test.rb` (update with create tests)

### Modified files:
- `config/routes.rb` — Add new API routes
- `app/controllers/api/v1/accounts_controller.rb` — Add `create` action
- `app/controllers/api/v1/categories_controller.rb` — Add `create` action
- `app/controllers/api/v1/merchants_controller.rb` — Add `create` action
- `app/views/api/v1/accounts/show.json.jbuilder` — Ensure it supports create response
- `spec/swagger_helper.rb` — Add new schemas
- `docs/api/openapi.yaml` — Regenerated

---

## 8. Verification Strategy

1. **Unit tests**: Test each new API endpoint (create account, category, merchant, budget, transfer, recurring)
2. **Integration test**: Create a fixture YNAB JSON response, run the migration rake task against a test Sure instance, verify all entities created correctly
3. **ID mapping verification**: Confirm transactions reference correct accounts, categories, and merchants after migration
4. **Amount verification**: Spot-check that YNAB milliunit amounts convert correctly (e.g., YNAB `-150000` → Sure `150.00` expense)
5. **Transfer verification**: Confirm paired transactions are linked as transfers in Sure
6. **Budget verification**: Confirm monthly budgets with correct category allocations
7. **Idempotency test**: Run migration twice, verify no duplicates created (via `external_id`)
8. **Run standard CI**: `bin/rails test`, `bin/rubocop -f github -a`, `bin/brakeman --no-pager`
