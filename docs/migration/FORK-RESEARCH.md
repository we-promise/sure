# Sure Finance Fork Research — Holistic Financial Planner Vision

> **Date:** 2026-02-19
> **Goal:** Fork Sure Finance and extend it into a single-app, holistic financial planner that matches (and exceeds) the personal spreadsheet workflow.
> **Source repo:** https://github.com/we-promise/sure

---

## 1. Background: Why Fork Sure?

Sure (community fork of Maybe Finance, ~$1M of original development) provides a production-grade foundation:
- Self-hosted, open-source (AGPLv3)
- Ruby on Rails, Docker-ready
- 10,000+ institution support via Plaid
- Account syncing, transaction management, categorization rules
- Budget system with category hierarchy
- Net worth tracking, investment holdings
- Multi-user family model

Rather than building from scratch or continuing to bolt features onto the current Next.js app, forking Sure gives a head start on the hard infrastructure (Plaid integration, account syncing, transaction imports) and lets us focus effort on the budget/planning features that matter most.

---

## 2. Sure's Current Architecture

### Tech Stack
- **Backend:** Ruby on Rails
- **Database:** PostgreSQL (UUIDs as PKs)
- **Frontend:** Rails views + Hotwire/Turbo (server-rendered with Turbo Frames for SPA-like updates)
- **Background jobs:** Sidekiq + Redis
- **Deployment:** Docker Compose
- **AI/LLM:** Optional Ollama integration for auto-categorization suggestions

### Key Data Model (Budget-Related)

```
budgets
├── id              (uuid PK)
├── family_id       (FK → families)
├── start_date      (date, NOT NULL)
├── end_date        (date, NOT NULL)
├── budgeted_spending (decimal 19,4)
├── expected_income   (decimal 19,4)
├── currency        (string, NOT NULL)
├── created_at / updated_at
└── UNIQUE INDEX (family_id, start_date, end_date)

budget_categories
├── id              (uuid PK)
├── budget_id       (FK → budgets)
├── category_id     (FK → categories)
├── budgeted_spending (decimal 19,4, NOT NULL)
├── currency        (string, NOT NULL)
├── created_at / updated_at
└── UNIQUE INDEX (budget_id, category_id)

categories
├── id              (uuid PK)
├── family_id       (FK → families)
├── name            (string, NOT NULL)
├── parent_id       (self-referencing FK → categories)  ← hierarchy
├── classification  (string, default "expense")         ← "expense" or "income"
├── color           (string, default "#6172F3")
├── lucide_icon     (string, default "shapes")
├── created_at / updated_at
└── INDEX (family_id)
```

### How Sure's Budget System Works

1. **Budget = a time period.** One budget record per month per family. NOT one budget per category. The budget stores two top-level numbers: total `budgeted_spending` and `expected_income`.

2. **Budget categories = allocations.** The `budget_categories` join table breaks down the total budget into per-category allocations. "This month, $500 goes to Groceries, $1800 to Rent, etc."

3. **Category hierarchy.** Categories have `parent_id` for grouping. HOUSING is a parent; Mortgage, Insurance, Property Taxes are children. The `BudgetCategory::Group` class handles rollup display.

4. **Subcategory budget inheritance.** A subcategory can either have its own budget allocation or "inherit" from the parent category's budget (shared pool).

5. **Actuals are always computed.** The `Budget` model delegates to `IncomeStatement` (a service object) which queries actual transactions for the budget's date range. No stored actuals — always derived from transaction data.

6. **IncomeStatement service.** Computes:
   - `expense_totals(period:)` — total expenses in a date range
   - `income_totals(period:)` — total income in a date range
   - `median_expense(interval: "month", category:)` — historical median for a category
   - `avg_expense(category:)` — historical average
   - Category-level breakdowns with rollup

7. **Budget edit is a wizard.** Step 1: enter total budgeted spending + expected income (with AI auto-suggest based on historical medians). Step 2: allocate spending across categories.

8. **Family model.** Everything belongs to a `family`, not a `user`. Multiple users in one family. The family has settings like `month_start_day`, `locale`, `date_format`.

9. **Monthly navigation.** Budget controller redirects to current month by default. Users navigate month-by-month with prev/next. Budget params use "feb-2026" format.

### Sure's Budget UI Structure

```
budgets/show.html.erb
├── _budget_header.html.erb       — month name, prev/next arrows
├── _budget_donut.html.erb        — donut chart of allocations
├── _budgeted_summary.html.erb    — expected income vs actual, budgeted vs spent
├── _actuals_summary.html.erb     — income/expense category percentages
├── _budget_categories.html.erb   — category list with rollup groups
└── _over_allocation_warning.html.erb

budget_categories/show.html.erb   — single category detail
├── donut chart for that category
├── overview: spent, budgeted, remaining, status, monthly averages
└── recent transactions list

budget_categories/index.html.erb  — allocation editor (wizard step 2)
├── per-category budget amount inputs
├── uncategorized catch-all
└── confirm button
```

### Key Budget Model Methods

```ruby
# Budget
available_to_spend      = budgeted_spending - actual_spending
allocated_spending      = sum of all budget_category.budgeted_spending
available_to_allocate   = budgeted_spending - allocated_spending
actual_spending         = computed from transactions via IncomeStatement
actual_income           = computed from transactions via IncomeStatement
remaining_expected_income = expected_income - actual_income
estimated_spending      = median historical expense (for auto-suggest)

# BudgetCategory
actual_spending         = transactions in that category for this period
available_to_spend      = budgeted_spending - actual_spending
avg_monthly_expense     = historical average
median_monthly_expense  = historical median
suggested_daily_spending = available_to_spend / remaining_days
```

---

## 3. The Personal Spreadsheet Model

The existing personal spreadsheet (`Long Term Goals - Living Expenses, Projected income.csv`) represents the target UX. It's structured as a two-sided annual plan:

### Left Side: Projected Income
```
General Source → Specific Source → Monthly (Gross) → Monthly (Net) → Annual (Gross) → Annual (Net)
Gross Wages   → Juan            → $4,023.09       → $3,317.64     → $48,277.08     → $39,811.67
Gross Wages   → Kathya          → $3,254.32       → $2,598.20     → $39,051.85     → $31,178.36
Dividends     → Fidelity        →                 →               → $230           →
Interest      → Savings         → $35.00          →               → $420           →
───────────────────────────────────────────────────────────────────────────────────────
TOTAL GROSS                      → $7,312.41       →               → $87,328.93     → $70,990.03
```

Also tracks: actual monthly net pay by person (Jan-Dec columns), with running annual comparison.

### Right Side: Living Expenses
```
Category Group → Line Item        → Monthly → Non-Monthly → Annual    → Last Paid → Jan  → Feb  → ... → Dec
HOUSING        → Mortgage/rent    → $0      → $1,800      → $21,600  → 12.29.23
               → TPU              → $0      → $206        → $2,472   → 12.1
               → Telephone        → $0      → $94         → $1,128   → 12.14.23
               → Internet         → $0      → $105        → $1,260   → 12.16.23
               → Total Housing    → $2,255  → $422.77     → $27,060            → $15  → -$37 → ...
GROCERIES      → Total Groceries  → $385    → $0          → $4,620             → -$368 → $140 → ...
TRANSPORTATION → Insurance        → $0      → $3,600      → $0       → 12.5.23
               → Gas and oil      → $0      → $120        → $1,440
               → Total Transport  → $120    → $3,881      → $1,440             → $0   → -$36 → ...
```

### Key Spreadsheet Concepts

1. **Monthly vs Non-Monthly amounts** — Two separate columns. Monthly = recurring charges. Non-Monthly = annual/semi-annual payments (car insurance $3,600/yr, tabs $111/yr). The Annual column derives from these.

2. **Jan-Dec variance columns** — Show actual-minus-budgeted per category per month. Positive = under budget. Negative = over budget. This is the core feedback loop.

3. **Income by person and source** — Tracks Juan and Kathya separately with gross/net for each paycheck. Also dividends, interest, rental income.

4. **Category groups with rollup** — HOUSING group totals across Mortgage, TPU, Phone, Internet, etc. Same for TRANSPORTATION, ENTERTAINMENT, etc.

5. **Savings as an expense line** — "Pay yourself first" — Fidelity, SoFi, Crypto are budget line items under SAVINGS.

6. **Tax estimation section** — Federal brackets, withholdings, quarterly estimates, projected refund/payment.

7. **Last Paid tracking** — When was the last payment for non-monthly items.

8. **Annual summary** — Bottom row shows total variance per month and YTD.

---

## 4. Gap Analysis: Sure vs Spreadsheet vs Current App

### What Sure Has That the Current App Doesn't
| Feature | Sure | Current App |
|---|---|---|
| Family/household model | ✅ `families` table, multi-user | ❌ Single userId |
| Budget = time period | ✅ One budget per month | ❌ Budget = category (flat) |
| Budget category allocations | ✅ `budget_categories` join table | ❌ Budget amount on budget row |
| Category hierarchy | ✅ `parent_id` on categories | ⚠️ `parentId` exists but unused in budgets |
| Income tracking on budget | ✅ `expected_income` field | ❌ No income concept in budgets |
| Historical medians for auto-suggest | ✅ IncomeStatement service | ❌ Not implemented |
| Plaid integration (10k+ institutions) | ✅ Production-ready | ❌ Schema exists but not connected |
| Category classification (income/expense) | ✅ `classification` field | ⚠️ `categoryType` exists but separate from budgets |
| Turbo/Hotwire for snappy UI | ✅ | N/A (React/TanStack) |

### What the Spreadsheet Has That Sure Doesn't
| Feature | Spreadsheet | Sure |
|---|---|---|
| Monthly vs Non-Monthly amounts | ✅ Two columns per line item | ❌ Single `budgeted_spending` per category |
| Annual budget plan view | ✅ One sheet = one year | ❌ Month-by-month only |
| Per-month variance (Jan-Dec) | ✅ Over/under per category per month | ❌ Only shows current month |
| Income by person and source | ✅ Juan/Kathya gross/net by source | ❌ Single `expected_income` number |
| Tax estimation | ✅ Brackets, withholdings, refund calc | ❌ Not present |
| Last Paid date tracking | ✅ Per non-monthly item | ❌ Not tracked |
| Savings as budget line items | ✅ Under SAVINGS group | ❌ No special handling |
| Non-monthly payment scheduling | ✅ Semi-annual insurance, annual tabs | ❌ Only monthly allocations |

### What the Current App Has That Sure Doesn't
| Feature | Current App | Sure |
|---|---|---|
| Investment tracking (stocks, holdings) | ✅ Full portfolio management | ⚠️ Basic holdings from Plaid |
| Debt management | ✅ `debts` table with payoff projections | ❌ Not present |
| Goals system | ✅ `goals` table with optimization | ❌ Not present |
| Scenario projections / what-if | ✅ Components exist | ❌ Not present |
| Net worth snapshots | ✅ Historical tracking | ✅ Also has this |

---

## 5. Proposed Vision: Holistic Financial Planner (Sure Fork)

### Core Principle
One app that replaces the spreadsheet entirely. If it can't do what the spreadsheet does, people will keep the spreadsheet.

### Schema Extensions Needed on Sure's Base

#### A. Income Sources Table (NEW)
```
income_sources
├── id              (uuid PK)
├── family_id       (FK → families)
├── user_id         (FK → users, nullable — which family member)
├── source_type     (enum: wages, dividends, interest, rental, business, pension, other)
├── name            (string — "Juan GenCare", "Fidelity Dividends")
├── gross_amount    (decimal)
├── net_amount      (decimal)
├── frequency       (enum: per_paycheck, monthly, quarterly, annual, one_time)
├── paychecks_per_month (integer, nullable — for per-paycheck frequency)
├── is_active       (boolean)
├── start_date      (date)
├── end_date        (date, nullable)
├── notes           (text)
└── timestamps
```
Links to a budget via: `budget.expected_income = sum of income_sources for that period`

#### B. Extend budget_categories
```
budget_categories (add columns)
├── monthly_amount      (decimal — recurring monthly cost)
├── non_monthly_amount  (decimal — annual/semi-annual costs)
├── payment_frequency   (enum: monthly, quarterly, semi_annual, annual, as_needed)
├── last_paid_date      (date, nullable)
├── next_due_date       (date, nullable)
```
The existing `budgeted_spending` becomes the computed monthly allocation (= monthly_amount + non_monthly_amount amortized).

#### C. Annual Budget Plan (NEW — or derived)
Could be a view/service that aggregates 12 monthly budgets into a yearly plan. Or a separate table:
```
annual_budget_plans
├── id
├── family_id
├── year            (integer)
├── total_projected_income_gross (decimal — derived)
├── total_projected_income_net   (decimal — derived)
├── total_budgeted_expenses      (decimal — derived)
├── notes
└── timestamps
```
Probably better as a service/computed view rather than stored data.

#### D. Tax Estimation (NEW)
```
tax_profiles
├── id
├── family_id
├── user_id         (FK — per person in household)
├── tax_year        (integer)
├── filing_status   (enum: single, married_joint, married_separate, head_of_household)
├── federal_withheld    (decimal)
├── state_withheld      (decimal)
├── social_security     (decimal)
├── medicare            (decimal)
├── other_withholdings  (jsonb — paid_family_leave, l_n_i, etc.)
├── quarterly_estimates (decimal)
├── notes
└── timestamps
```

#### E. Debt Management (port from current app)
Sure doesn't have a debts table. Port the existing `debts` schema with payoff projections.

#### F. Goals System (port from current app)
Port the existing `goals` schema with target amounts, timelines, optimization.

### Feature Roadmap (Rough Priority)

1. **Fork & deploy Sure** — Get it running, understand the codebase
2. **Income sources** — Add the table, wire into budget expected_income
3. **Monthly vs non-monthly budget amounts** — Extend budget_categories
4. **Annual plan view** — New page showing 12-month grid (the spreadsheet view)
5. **Per-month variance tracking** — Jan-Dec columns showing over/under per category
6. **Debt management** — Port from current app
7. **Goals & savings tracking** — Port from current app, integrate with budget (savings as expense line)
8. **Tax estimation** — New module
9. **Investment portfolio** — Port from current app or extend Sure's basic holdings
10. **Scenario planning / what-if** — Port from current app

---

## 6. Technical Considerations

### Rails vs Next.js
Sure is Rails + Hotwire. The current app is Next.js/React + TanStack. Forking Sure means committing to Rails. Pros:
- Rails is battle-tested for CRUD-heavy financial apps
- Hotwire/Turbo gives SPA feel with server rendering (simpler than React hydration)
- Sure's Plaid integration, syncing, background jobs are already wired up
- Sidekiq for reliable background processing (reconciliation, import, etc.)

Cons:
- Different tech stack from current app (would need to learn Rails or port back)
- React ecosystem has more UI component libraries

### Data Migration
If forking Sure, would need to migrate existing data from the current app's Postgres schema into Sure's schema. Key mappings:
- `unified_transactions` → Sure's `transactions` (different column names, same concept)
- `categories` → Sure's `categories` (add parent_id hierarchy)
- `financial_accounts` → Sure's `accounts`
- `budgets` → Would need restructuring (flat → period-based)

### Deployment
Sure ships with Docker Compose. Could deploy to same infrastructure. Needs:
- PostgreSQL
- Redis (for Sidekiq)
- Web server (Puma)
- Worker process (Sidekiq)

---

## 7. Open Questions

1. **Rails or keep React?** Fork Sure (Rails) or port Sure's data model patterns into the existing Next.js app?
2. **Multi-person priority?** How important is tracking Juan vs Kathya separately vs just total household?
3. **Plaid integration?** Currently manual transaction entry. Worth keeping Sure's Plaid integration?
4. **Tax module scope?** Simple bracket estimation or full tax planning (deductions, credits, quarterly estimates)?
5. **Historical data?** Import existing spreadsheet data as historical budgets?
6. **Mobile app?** Rails + Hotwire is mobile-friendly but not native. PWA sufficient?

---

## 8. References

- **Sure GitHub:** https://github.com/we-promise/sure
- **Sure Website:** https://sure.am/
- **Sure Wiki:** https://github.com/we-promise/sure/wiki
- **Sure Contributing Guide:** https://github.com/we-promise/sure/blob/main/CONTRIBUTING.md
- **Maybe Finance (archived original):** https://github.com/maybe-finance/maybe
- **Sure overview article:** https://www.vibesparking.com/en/blog/tools/personal-finance/2025-12-25-sure-personal-finance-app-maybe-fork/
