# Sprint: Migrate Buddy App Features to Sure Finance Fork

> **Date:** 2026-02-19
> **Goal:** Port the buddy app's import system, goals/savings tracking, and investment import logic into the Sure Finance fork. Also add savings-as-budget concept with inverted over/under logic.
> **Source (buddy app):** `/home/default/Desktop/dev/Financial-Planner/app`
> **Target (Sure fork):** `https://github.com/we-promise/sure` (running at `http://10.0.0.227:3333`)

---

## 1. What We're Migrating (and NOT migrating)

### Migrating FROM buddy app → Sure fork:
1. **Import system** — Institution-specific CSV parsers, auto-detection, duplicate detection, investment import
2. **Goals/savings tracking** — Goal schema, contributions, auto-tracking rules, linked accounts
3. **Savings-as-budget** — Budget line items for savings where going over is good (inverted logic)
4. **Investment transaction import** — Buy/sell/dividend/reinvestment with holding updates

### NOT migrating (Sure already has better versions):
- Transaction CRUD (Sure has it with Plaid integration)
- Account management (Sure has it with sync)
- Category hierarchy (Sure already has parent_id)
- Budget structure (Sure's period-based model is better than buddy's flat model)
- Multi-user/family (Sure has it, buddy doesn't)

### NOT migrating (out of scope for this sprint):
- Spreadsheet annual plan view (future sprint)
- Tax estimation module (future sprint)
- Monthly vs non-monthly budget amounts (future sprint)
- Scenario projections / what-if tools (future sprint)

---

## 2. Buddy App Import System — What Exists

### Architecture
The buddy app has a client-side import flow built in React:

**Flow:** Upload CSV → Auto-detect institution → Parse → Preview (editable table) → Select/skip transactions → Import

**Key files:**
- `src/routes/import/index.tsx` — Single-page import UI (997 lines)
- `src/lib/import/import-service.ts` — Import service with session management, duplicate detection, DB writes
- `src/lib/import/csv-parser.ts` — CSV parser using institution configs
- `src/lib/import/institutions/index.ts` — 10 institution configurations
- `src/lib/import/types.ts` — TypeScript types for import system

### Supported Institutions (10 total)

| Institution | Delimiter | Key Headers | Transaction Types |
|---|---|---|---|
| **Buddy** | `;` (semicolon) | Date, Note, Amount, Head categor, Category, Paid By, Currency | expense/income by amount sign, transfers when $0 |
| **Copilot Money** | `,` | Date, Merchant, Category, Account, Amount, Note | expense/income by amount sign |
| **Monarch Money** | `,` | Date, Merchant, Category, Account, Amount, Original Statement, Notes | expense/income by amount sign |
| **Bank Generic** | `,` | Date, Description, Amount, Category | deposit/withdrawal/transfer/fee |
| **Fidelity (Transactions)** | `,` | Run Date, Action, Symbol, Description, Quantity, Price, Commission, Amount | buy/sell/dividend/reinvestment/transfer/fee/interest |
| **Fidelity (Holdings)** | `,` | Symbol, Description, Quantity, Last Price, Current Value, Cost Basis Total | holdings snapshot (treated as buys) |
| **Fidelity (Orders)** | `,` | Run Date, Action, Symbol, Description, Currency*, Price*, Commission, Amount | Same as transactions (has column bug workaround) |
| **Charles Schwab** | `,` | Date, Action, Symbol, Description, Quantity, Price, Fees & Comm, Amount | buy/sell/dividend/reinvestment/transfer/interest/fee |
| **Vanguard** | `,` | Trade Date, Transaction Type, Symbol, Investment Name, Shares, Share Price, Commission Fees, Principal Amount | buy/sell/dividend/reinvestment/deposit/withdrawal |
| **Robinhood** | `,` | Activity Date, Trans Code, Symbol, Description, Quantity, Price, Amount | BUY/SELL/CDIV/OCDIV/ACH/ACATS/INT/GOLD |
| **E*TRADE** | `,` | TransactionDate, TransactionType, Symbol, Description, Quantity, Price, Commission, Amount | Bought/Sold/Dividend/Reinvested Dividend/Interest |

### Auto-Detection
`detectInstitution(headers)` checks CSV headers against each config's `detectHeaders` function. Tries comma delimiter first, then semicolon. Falls back to `bank_generic` if no match.

### Duplicate Detection
Checks existing transactions within ±3 days with confidence scoring:
- Date match (exact = 30pts, within 1 day = 20pts)
- Amount match (exact = 40pts, within 1% = 25pts)
- Description similarity (Jaccard >0.8 = 30pts, >0.5 = 15pts)
- Threshold: ≥70 confidence = duplicate

### Investment Import
Two paths:
1. **Holdings import** (Fidelity holdings CSV): Creates/updates `investmentHoldings` records directly. Preserves manual prices.
2. **Transaction import**: Creates `unifiedTransactions` + finds/creates/updates holdings for buy/sell/reinvestment. Updates share counts and cost basis proportionally on sells.

### Import UI Features
- Drag & drop file upload
- Institution selector dropdown (Buddy, Copilot, Monarch, Bank Generic, Auto-detect)
- Default account selector
- Preview table with:
  - Checkbox per row (skip/include)
  - Date, description, category hierarchy, paid-by badge, transfer indicator
  - Per-row account selector
  - Amount (colored positive/negative)
  - Edit button → modal with date, amount, description, account, category (hierarchical), transfer toggle + destination account
- Summary bar: transaction count, total income, total expenses, transfer count
- Bulk account assignment
- Batch insert (100 at a time) with `importBatchId` for traceability

---

## 3. Sure's Import System — What It Already Has

(See `IMPORT-SYSTEM-RESEARCH.md` for full details)

### Sure's strengths (keep as-is):
- 5-step wizard: Upload → Configure → Clean → Map → Confirm
- **Inline cell editing** in clean step (Turbo Frames per-cell, auto-submit on blur)
- **Error row filtering** (toggle "All rows" / "Error rows")
- **Template reuse** — remembers column mapping for repeat imports from same account
- **Polymorphic mapping system** — maps CSV categories/tags/accounts to app objects with "Create new" option
- **Background processing** with Sidekiq (import + revert)
- **Multi-format number parsing** (US, EU, French)
- **PDF import with AI extraction**
- **Revert capability** — can undo an entire import

### Sure's gaps (what needs to be added):
- No institution-specific parsers (buddy has 10, Sure has a generic column mapper)
- No auto-detection of CSV format
- No duplicate detection
- No investment transaction import (buy/sell/dividend with holding management)
- No holdings import (snapshot of current positions)
- No confidence scoring on parsed rows
- No batch ID tracking for import traceability

---

## 4. Migration Plan: Import System

### Strategy: Extend Sure's import, don't replace it

Sure's generic column-mapping approach is more flexible than buddy's hardcoded configs. The migration should add institution presets ON TOP of Sure's existing system, not replace it.

### 4.1 Add Institution Presets to Sure

Create a new model/concept: `Import::InstitutionPreset`

```
Import::InstitutionPreset
├── name           (string — "buddy", "fidelity", "copilot", etc.)
├── display_name   (string — "Buddy Budgeting App")
├── delimiter      (string — "," or ";")
├── date_format    (string)
├── column_map     (jsonb — maps CSV columns to Sure's column keys)
├── detect_headers (jsonb — list of required headers for auto-detection)
├── action_map     (jsonb — maps action strings to transaction types)
├── notes          (text)
```

When a user uploads a CSV, Sure should:
1. Try to auto-detect the institution from headers (new step before Configure)
2. If matched, auto-fill the Configure step with the preset's column mapping
3. User can still override any mapping (Sure's existing flexibility preserved)
4. If not matched, fall through to Sure's existing manual configuration

### 4.2 Add Duplicate Detection to Sure

Port the buddy app's duplicate detection logic into Sure's import pipeline:
- Run after CSV parsing, before the Clean step
- Flag potential duplicates with confidence scores
- Show duplicates in the Clean step with a third toggle: "All rows" / "Error rows" / "Potential duplicates"
- Let users decide per-row: import, skip, or merge

### 4.3 Add Investment Import Type

Sure has `TradeImport` but it's basic. Extend it with:
- Holdings snapshot import (like Fidelity holdings CSV)
- Auto-create/update holdings on buy/sell/reinvestment
- Cost basis tracking (FIFO proportional reduction on sells)
- Preserve manual prices (don't overwrite user-set prices)

### 4.4 Add Batch Tracking

Add `import_batch_id` to Sure's transactions table so imports can be traced and reverted cleanly. (Sure already has revert — just needs the batch ID for precision.)

---

## 5. Goals & Savings System — What Buddy Has

### Schema

**goals table:**
- `id`, `userId`, `name`, `description`
- `goalType` enum: emergency_fund, house_down_payment, vacation, education, debt_payoff, retirement, vehicle, wedding, custom
- `targetAmount`, `currentAmount`, `targetDate`
- `icon`, `color`, `priority`
- `isCompleted`
- `useLinkedAccounts` — when true, `currentAmount` = sum of linked account balances (no manual contributions)

**goal_contributions table:**
- Links transactions to goals
- `goalId`, `transactionId`, `amount`, `contributionDate`
- `contributionType` enum: manual, auto_category, auto_account, auto_pattern, recurring
- `isPartial` — only part of transaction goes to this goal (e.g., $100 of $500 paycheck → emergency fund)
- `matchedRuleId` — which auto-tracking rule matched

**goal_auto_tracking_rules table:**
- Defines rules for automatic contribution linking
- `ruleType`: category, account, pattern, transaction_type
- `conditions` (JSON): `{ "categoryId": "abc123" }`, `{ "descriptionPattern": "payroll|salary" }`, `{ "transactionTypes": ["income"] }`
- `contributionMode`: full, percentage, fixed
- `contributionValue`: for percentage (0.10 = 10%) or fixed ($200)
- `priority`: higher = first (for when multiple rules match)
- `isActive`, `matchCount`, `lastMatchedAt`, `totalContributed`

**goal_linked_accounts table:**
- Links financial accounts to goals for balance-based tracking
- When `useLinkedAccounts=true`, goal's `currentAmount` = sum of linked account balances
- Unique constraint: one account per goal

### Key Concepts

1. **Two tracking modes:**
   - **Manual/auto contributions**: Individual transactions tagged as contributing to a goal. `currentAmount` = sum of contributions.
   - **Linked accounts**: Goal progress = sum of linked account balances. No individual contribution tracking. Good for "my emergency fund is my savings account balance."

2. **Auto-tracking rules**: When new transactions come in, rules automatically create contributions. E.g., "Any transaction in category 'Savings' goes to my Emergency Fund goal."

3. **Partial contributions**: A single transaction can be split across multiple goals. "$500 paycheck → $100 to emergency fund, $200 to vacation fund."

---

## 6. Savings-as-Budget — THE MISSING PIECE

### The Problem
Sure treats all budget categories the same: you set a spending limit, and going over is bad. But savings categories are the opposite — budgeting $1,500/mo to savings means you WANT to hit or exceed that number.

### The Solution: Category Classification + Inverted Logic

Sure already has `categories.classification` = "expense" or "income". Add a third option: **"savings"**.

### How It Should Work

1. **Budget category marked as savings**: When a category's classification = "savings", the budget UI inverts:
   - Progress bar is GREEN when you've saved the full amount or more
   - Going OVER budget = good (extra savings)
   - Going UNDER budget = warning (haven't saved enough)
   - Remaining shows "left to save" instead of "left to spend"

2. **Links to goals**: A savings budget category can be linked to a goal. When you budget $1,500/mo to "Emergency Fund Savings":
   - Transactions categorized as "Emergency Fund Savings" count as both budget spending AND goal contributions
   - The budget shows "$1,500 of $1,500 saved" (green)
   - The linked goal shows progress updated by the same amount

3. **Budget summary**: The budget summary should separate:
   - **Spending budget**: $3,000 budgeted, $2,450 spent, $550 remaining
   - **Savings budget**: $1,500 budgeted, $1,500 saved (on track)
   - **Total budget**: $4,500 allocated

### Schema Changes Needed

```ruby
# categories table — add "savings" to classification enum
# Currently: ["expense", "income"]
# New: ["expense", "income", "savings"]

# budget_categories table — add goal link
# New column:
#   goal_id (FK → goals, nullable)
#   When present, contributions auto-feed into the goal
```

### UI Changes

In the budget view, savings categories should:
- Show a different icon (piggy bank or target instead of shopping bag)
- Show progress bar in reverse (filling up = good)
- Use positive language: "Saved $1,200 of $1,500" not "Spent $1,200 of $1,500"
- Over-budget badge should be green "Extra savings!" not red "Over budget"
- Link to the associated goal page if one exists

---

## 7. Migration Plan: Goals & Savings

### 7.1 Port Goals Schema to Sure (Rails migration)

```ruby
# goals
create_table :goals, id: :uuid do |t|
  t.references :family, type: :uuid, null: false, foreign_key: true
  t.references :user, type: :uuid, foreign_key: true  # which family member (nullable = shared goal)
  t.string :name, null: false
  t.text :description
  t.string :goal_type, null: false, default: "custom"
  # Types: emergency_fund, house_down_payment, vacation, education, debt_payoff, retirement, vehicle, wedding, custom
  t.decimal :target_amount, precision: 19, scale: 4, null: false
  t.decimal :current_amount, precision: 19, scale: 4, null: false, default: 0
  t.date :target_date
  t.string :icon
  t.string :color
  t.integer :priority, null: false, default: 0
  t.boolean :is_completed, null: false, default: false
  t.boolean :use_linked_accounts, null: false, default: false
  t.string :currency, null: false
  t.timestamps
end

# goal_contributions
create_table :goal_contributions, id: :uuid do |t|
  t.references :goal, type: :uuid, null: false, foreign_key: true
  t.references :transaction, type: :uuid, foreign_key: { to_table: :transactions }
  t.decimal :amount, precision: 19, scale: 4, null: false
  t.date :contribution_date, null: false
  t.string :contribution_type, null: false, default: "manual"
  # Types: manual, auto_category, auto_account, auto_pattern, recurring
  t.boolean :is_partial, null: false, default: false
  t.text :notes
  t.uuid :matched_rule_id
  t.timestamps
end

# goal_auto_tracking_rules
create_table :goal_auto_tracking_rules, id: :uuid do |t|
  t.references :goal, type: :uuid, null: false, foreign_key: true
  t.string :name, null: false
  t.text :description
  t.string :rule_type, null: false  # category, account, pattern, transaction_type
  t.jsonb :conditions, null: false
  t.string :contribution_mode, null: false, default: "full"  # full, percentage, fixed
  t.decimal :contribution_value, precision: 19, scale: 4
  t.integer :priority, default: 0
  t.boolean :is_active, null: false, default: true
  t.integer :match_count, default: 0
  t.datetime :last_matched_at
  t.decimal :total_contributed, precision: 19, scale: 4, default: 0
  t.timestamps
end

# goal_linked_accounts
create_table :goal_linked_accounts, id: :uuid do |t|
  t.references :goal, type: :uuid, null: false, foreign_key: true
  t.references :account, type: :uuid, null: false, foreign_key: true
  t.timestamps
end
add_index :goal_linked_accounts, [:goal_id, :account_id], unique: true
```

### 7.2 Add Savings Classification

```ruby
# Migration: add "savings" to categories.classification enum
# Sure currently uses string column, so just allow the new value

# Add goal_id to budget_categories
add_reference :budget_categories, :goal, type: :uuid, foreign_key: true
```

### 7.3 Build Goal UI in Sure

Port the buddy app's goal components (adapted to Rails/Hotwire):
- Goals list page
- Goal detail page (progress ring, contribution timeline, linked accounts)
- Goal creation/edit form (type selector with icons)
- Auto-tracking rule builder
- Contribution linking from transaction detail page

### 7.4 Budget Savings Integration

Modify Sure's existing budget views:
- `BudgetCategory::Group` — handle savings classification differently
- `_budget_categories.html.erb` — invert progress bar for savings categories
- Budget summary partials — separate spending vs savings totals
- `BudgetCategory#available_to_spend` → for savings, rename to `remaining_to_save` with inverted logic

---

## 8. Sprint Priorities (Ordered)

### Phase 1: Foundation
1. **Fork Sure repo** — Create private fork, set up dev environment
2. **Port goals schema** — Rails migrations for goals, contributions, auto-tracking rules, linked accounts
3. **Add savings classification** — Extend categories with "savings" type
4. **Add goal_id to budget_categories** — Link savings budget lines to goals

### Phase 2: Import Enhancement
5. **Add institution presets** — Port buddy's 10 institution configs as presets for Sure's import wizard
6. **Add auto-detection** — Header-based CSV format detection before Configure step
7. **Add duplicate detection** — Confidence scoring, flagging in Clean step
8. **Enhance investment import** — Holdings snapshot, cost basis tracking, holding auto-management

### Phase 3: Goals & Savings UI
9. **Build goals CRUD** — List, create, edit, delete goals
10. **Build goal detail page** — Progress, contributions, linked accounts, auto-tracking rules
11. **Budget savings integration** — Inverted progress bars, savings totals, goal linking
12. **Auto-tracking engine** — Background job that matches new transactions to goal rules

### Phase 4: Polish
13. **Goal templates** — Pre-built goal types with suggested targets (emergency fund = 3-6 months expenses)
14. **Savings dashboard widget** — Quick view of all savings goals on main dashboard
15. **Import batch tracking** — Add batch IDs, improve revert precision

---

## 9. Files Reference (Buddy App)

### Import System
| File | Lines | What It Does |
|---|---|---|
| `src/routes/import/index.tsx` | 997 | Import page UI: upload, preview table, edit modal, summary |
| `src/lib/import/import-service.ts` | 686 | Import service: sessions, duplicate detection, DB writes, holding management |
| `src/lib/import/csv-parser.ts` | 331 | CSV parser: line splitting, field mapping, row validation, confidence scoring |
| `src/lib/import/institutions/index.ts` | 802 | 10 institution configs with column mappings, header detection, action mappers |
| `src/lib/import/types.ts` | 163 | TypeScript types: ParsedTransaction, ImportSession, InstitutionConfig, etc. |

### Goals System
| File | Lines | What It Does |
|---|---|---|
| `src/database/schema/goals.ts` | 207 | Schema: goals, goal_contributions, goal_auto_tracking_rules, goal_linked_accounts |
| `src/database/schema/enums.ts` | 131-141, 227-233 | Enums: goalTypeEnum (9 types), contributionTypeEnum (5 types) |
| `src/routes/goals/` | — | Goals pages (list, detail, create) |
| `src/components/goals/` | — | Goal components (dashboard, templates, contributions, optimization) |
| `src/lib/goals/` | — | Goal service logic (projections, optimization) |

---

## 10. Key Decisions to Make

1. **Institution presets: config file or DB?** Could store presets in a YAML/JSON config file (simpler, version controlled) or in a DB table (users could add custom presets). Recommendation: config file for built-in presets, DB table for user-defined custom mappings.

2. **Goals: per-user or per-family?** Buddy has per-user goals. Sure is family-based. Recommendation: goals belong to family but have optional `user_id` for "this is Juan's retirement fund" vs "this is our house down payment fund."

3. **Savings category auto-creation?** When user creates a goal, auto-create a matching savings category and budget line? Or keep them separate? Recommendation: offer to link during goal creation but don't force it.

4. **Contribution tracking: real-time or batch?** Auto-tracking rules could run on every new transaction (webhook-style) or as a periodic job. Recommendation: Sidekiq job triggered when transactions are created/imported, same pattern Sure uses for other post-transaction processing.
