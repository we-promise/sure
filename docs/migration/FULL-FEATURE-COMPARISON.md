# Full Feature Comparison: Buddy App vs Sure Finance

> **Date:** 2026-02-19
> **Purpose:** Identify EVERYTHING in the buddy app that should migrate, and EVERYTHING in Sure we haven't accounted for yet.

---

## 1. Feature-by-Feature Matrix

### Legend
- **BUDDY**: Feature exists in the buddy app
- **SURE**: Feature exists in Sure
- **MIGRATE**: Should port from buddy → Sure fork
- **KEEP**: Sure's version is better, keep it
- **BOTH**: Both have it, merge the best of each
- **NEW**: Neither has it, but the spreadsheet vision needs it
- **SKIP**: Not needed for the holistic planner vision

---

## 2. BUDDY FEATURES → What to Migrate

### 2.1 Budget Views (MIGRATE — your priority)

The buddy app has 3 dedicated budget views plus a budget CRUD system. These are the most important to migrate since you need to "see budgets clearly."

| Page | Route | What It Does | Migrate? |
|------|-------|--------------|----------|
| **Daily Budget** | `/budget/daily` | Today's spending vs daily budget allocation. Quick-add expense. Hourly spending chart. 4 summary cards (budget, spent, remaining, % used). Category breakdown pie chart. Recent transactions. | **YES** — daily pulse view |
| **Monthly Budget** | `/budget/monthly` | Month-at-a-glance. Calendar heat map (spending per day). Category bar chart. Budget vs actual per category table. Delete budget button per row. 4 summary cards. Transaction table. | **YES** — primary budget view |
| **Yearly Budget** | `/budget/yearly` | 8-tab panel: Overview, Forecasts, Wealth Metrics, Goal Calculator, Insights, What-If, 50/30/20 chart. Scenario projections. Trajectory gauge. | **PARTIAL** — overview tab yes, advanced analytics deferred |
| **Budget List** | `/budgets` | All budgets with filters (period, amount range, category). Summary cards (total budgets, total budgeted, total spent). Quick-nav to daily/monthly/yearly. | **YES** — budget management |
| **Budget Detail** | `/budgets/$id` | Single budget: edit form (name, amount, period, category, account). Transaction history for that budget. Progress bar. Quick-nav. | **YES** — budget editing |
| **New Budget** | `/budgets/new` | Create budget form. | **YES** |
| **Budget Analytics** | `/budget-analytics` | Dedicated analytics page for budget performance. | **YES** — merge into reports |

**What Sure has for budgets:** Period-based budgets (1 per month per family), budget categories as allocations, donut chart, summary cards, category rollup with parent groups, wizard for creating/editing. Sure's structure is better (period-based vs buddy's flat per-category model), but buddy's views are richer.

**Migration strategy:** Keep Sure's period-based budget data model. Port buddy's UI concepts (daily pulse, calendar heat map, yearly overview tabs) into Sure's Hotwire views. The spreadsheet-style budget-vs-actual table is the priority.

### 2.2 Spending Analysis (MIGRATE)

| Page | Route | What It Does | Migrate? |
|------|-------|--------------|----------|
| **Spending** | `/spending` | Spending trends, category breakdowns, merchant analysis, time-series charts | **YES** |
| **Cash Flow** | `/cash-flow` | Income vs expenses over time, net cash flow, projections | **YES** |

**What Sure has:** The Reports page (`/reports`) covers summary dashboard, net worth, budget performance, transaction breakdown, trends & insights, investment flows, investment performance. Sure's reports are more comprehensive for the overview, but buddy's spending and cash flow pages offer more drill-down.

### 2.3 Recurring Transactions (BOTH — merge)

**Buddy app:**
- `/recurring` — 3 sub-pages: detect, history, templates
- `src/lib/recurring/` and `src/lib/recurring-transactions/` — detection algorithms, template system
- Schema in transactions table: `isRecurring`, `recurringFrequency`, `recurringGroupId`
- Auto-detection of patterns + manual recurring templates

**Sure:**
- `RecurringTransaction` model — auto-detection via `Identifier` job
- Expected day of month, amount variance (min/max/avg), next expected date
- `identify_patterns_for!` — scans transaction history for monthly patterns
- Manual creation from existing transactions (`create_from_transaction`)
- Settings for auto-detection (family-level toggle)
- Cleanup job for stale recurring transactions

**Sure's is more mature.** It has variance tracking (expected amount range), automatic pattern identification as a background job, and cleanup. Buddy's has templates and history views. **Merge:** Keep Sure's model, add buddy's template concept and history view.

### 2.4 Smart Rules Engine (BOTH — merge)

**Buddy app:**
- Full rule engine with conditions (14 operators) and actions (7 types)
- Condition fields: description, amount, signed_amount, account_id, category_id, merchant_name, transaction_type, date
- Operators: contains, not_contains, equals, not_equals, starts_with, ends_with, greater_than, less_than, between, in_list, etc.
- Actions: set_category, add_tags, set_tags, set_merchant, set_notes, append_notes, mark_reviewed
- Priority-based evaluation, stop-on-match option
- Rule runs tracking (audit log)
- UI: `/rules` page for CRUD

**Sure:**
- `Rule` model with conditions and actions (separate models)
- `Rule::Registry::TransactionResource` — transaction-specific rules
- Conditions as nested models with `Rule::Condition::Filter` pattern
- Actions as nested models with executors
- Rules can be imported/exported (RuleImport)
- Background job execution (`RuleJob`)
- Affected resource count preview before applying
- Display: conditions shown as human-readable strings

**Both are solid.** Sure's architecture (separate models for conditions/actions with registries) is cleaner than buddy's (JSON columns). But buddy has more condition operators. **Merge:** Keep Sure's model architecture, port buddy's operators and action types.

### 2.5 Transfer Detection (BOTH — merge)

**Buddy app:**
- `transfers` table: inflow + outflow transaction pairing
- `rejectedTransfers` table: prevents re-matching rejected pairs
- Status: pending, confirmed
- Types: funds_movement, cc_payment, loan_payment
- Auto-detection algorithm in `src/lib/transfers/`

**Sure:**
- `Transfer` model with `RejectedTransfer`
- Status: pending, confirmed
- Types derived from account type (loan_payment, cc_payment, investment_contribution, funds_movement)
- Validation: different accounts, opposite amounts, within date range, same family
- `TransferMatcher` service for auto-detection
- `/transfer_matches` controller for managing detected transfers

**Very similar.** Sure's is slightly more complete (investment_contribution type, same-family validation). **Keep Sure's.**

### 2.6 Investment Portfolio (MIGRATE)

**Buddy app:**
- `/portfolio` — Portfolio dashboard with accounts, holdings, analytics, transactions
- `/portfolio/holdings` — Holdings list with real-time prices
- `/portfolio/analytics` — Performance charts, allocation breakdown
- `/portfolio/accounts` — Investment account management
- `/portfolio/transactions` — Investment transaction history (buy/sell/dividend)
- `/stocks` — Stock screener, comparison tool, individual stock detail (`$symbol`)
- `src/lib/portfolio-analytics/` — Performance calculations
- `src/lib/stock-api/` — Live stock price API
- `src/lib/technical-indicators.ts` — RSI, MACD, moving averages
- `src/lib/quote-pricing.ts` — Quote pricing service
- `src/lib/stock-data.ts` — Stock data management
- Schema: `investments`, `stocks` tables, holdings tracking, cost basis methods (FIFO/LIFO/HIFO/specific/average)

**Sure:**
- Holdings from Plaid sync + manual trade entry
- `Trade` model for buy/sell/transfer
- `Holding` model with market data
- `Security` model with price syncing
- Investment account type with `Investment::Syncer`
- Investment statements, activity feed
- Crypto support (`Crypto`, `CoinbaseAccount`, `CoinstatsAccount`)

**Buddy's portfolio features are much richer** — screener, comparison tool, technical indicators, multiple cost basis methods. Sure has better data infrastructure (Plaid sync, multiple providers). **Migrate:** Port buddy's analytics views, screener, and technical analysis tools. Keep Sure's data sync infrastructure.

### 2.7 Debt Management (MIGRATE — Sure doesn't have it)

**Buddy app:**
- `/debt` — Debt management page
- Schema: debts table (name, type, originalAmount, currentBalance, interestRate, minimumPayment, dueDay, startDate, payoffDate, isPaidOff)
- Debt types: credit_card, student_loan, auto_loan, mortgage, personal_loan, medical, other
- Linked to financial accounts (optional)

**Sure:** Has Loan and CreditCard account types but NO dedicated debt management system (no payoff projections, no debt snowball/avalanche calculator, no interest tracking).

**MIGRATE fully.**

### 2.8 Assets & Net Worth (BOTH — merge)

**Buddy app:**
- `/assets` — Asset management (CRUD)
- `/assets/$id` — Asset detail
- `/assets/new` — Create asset
- `/net-worth` — Net worth dashboard with historical snapshots
- `/net-worth/health` — Financial health scoring
- Schema: assets table (name, type, currentValue, purchasePrice, purchaseDate, valuationMethod, depreciationRate)
- Asset types: real_estate, vehicle, investment, collectible, business, retirement_account, personal_property, cash, intellectual_property
- Net worth snapshots table (periodic snapshots of total assets, liabilities, net worth)

**Sure:**
- Property, Vehicle, OtherAsset account types
- Valuations system (historical value tracking per account)
- Balance sheet (BalanceSheet model)
- Net worth chart on dashboard
- Account sparklines for trend visualization

**Sure's valuation system is more elegant** (valuations as journal entries on accounts rather than separate snapshot table). But buddy has financial health scoring. **Keep Sure's model, port buddy's health scoring.**

### 2.9 Statements / Bank Statements (MIGRATE)

**Buddy app:**
- `/statements` — Bank statement reconciliation view

**Sure:** No dedicated statements page, but imports handle CSV statements. Sure does have account reconciliation (`Account::Reconcileable`, `Account::ReconciliationManager`).

**Port buddy's statements UI, integrate with Sure's reconciliation.**

### 2.10 Notifications System (MIGRATE — Sure doesn't have it)

**Buddy app:**
- Full notification schema: 20+ notification types
- Severity levels: info, low, medium, high, critical
- Budget warnings, goal progress, bill reminders, price alerts, security alerts
- Read/acknowledged/dismissed states with timestamps
- Expiration support
- Entity linking (transaction, budget, goal, account, etc.)
- Notification preferences in user settings (email, push, budget alerts, goal reminders, weekly/monthly reports)

**Sure:** No notification system. No alerts for budget overspending, upcoming bills, or goal milestones.

**MIGRATE fully.** This is essential for a holistic planner — you need to know when you're over budget or a bill is due.

### 2.11 Bills & Subscriptions (PARTIAL)

**Buddy app:**
- `/bills` — Bills tracking page
- `/subscriptions` — Subscriptions tracking page
- Transaction types include `bill` and `subscription`

**Sure:**
- Has a `subscriptions_controller.rb` but it's for the SaaS subscription (payment plan), NOT expense subscriptions
- Recurring transactions cover some of this (auto-detected monthly charges)

**MIGRATE** — Bills and subscriptions as distinct concepts (not just recurring transactions). A bill has a due date and amount due. A subscription has a renewal date and can be cancelled.

### 2.12 Merchants (BOTH — merge)

**Buddy app:**
- `/merchants` — Merchant management page
- Schema: merchants table (name, normalizedName, logoUrl, icon, color, suggestedCategoryId, source)
- User merchant overrides (custom category per merchant per user)
- Auto-detection from transactions (manual, plaid, csv sources)

**Sure:**
- `FamilyMerchant` model with auto-logo generation from BrandFetch API
- `ProviderMerchant` model (from Plaid/SimpleFin enrichment)
- Website URL → auto-generate logo
- Color assignment
- Per-family merchants (not per-user)

**Sure's merchant system is better** (auto-logo from website, family-scoped). **Keep Sure's, port buddy's category suggestion concept.**

### 2.13 Categories (BOTH — merge)

**Buddy app:**
- `/categories` — Category management with hierarchical tree
- Schema: categories table with parentId, categoryType (income/expense)
- Category templates (importable preset category trees)

**Sure:**
- Categories with parent_id hierarchy
- Classification: income, expense
- Category-specific icons (Lucide) and colors
- Category import/export
- Uncategorized catch-all

**Similar.** Sure's is family-scoped (better). Buddy has category templates for quick setup. **Keep Sure's, port buddy's template system.**

### 2.14 Tags (BOTH — merge)

**Buddy app:**
- Tags table (name, color, userId)
- Many-to-many with transactions (transactionTags join table)
- Use cases: vacation, tax-deductible, shared, reimbursable

**Sure:**
- Tags model with taggings (polymorphic many-to-many)
- Tag management UI
- Tags in transaction rules
- Tags in import mapping

**Sure's is better** (polymorphic tagging — can tag more than just transactions). **Keep Sure's.**

### 2.15 User Profile & Settings (BOTH — merge)

**Buddy app:**
- `/profile` — User profile page
- `/settings` — Application settings
- `/security` — Security settings
- userProfiles table: bio, phone, DOB, address, financial preferences (risk tolerance, annual income, employment, dependents, retirement planning — age, target, contribution, expected return rate)
- userSettings table: currency, timezone, theme, language, dateFormat, numberFormat, notification preferences
- userSessions table: device tracking, IP, location, last access

**Sure:**
- Settings organized into sections: profiles, preferences, bank_sync, providers, guides, hostings, securities, payments, api_keys, llm_usages, ai_prompts
- Family-level settings (month_start_day, locale, date_format, currency)
- MFA support
- SSO support
- Impersonation sessions (admin feature)
- API key management

**Sure's settings infrastructure is more complete** (SSO, MFA, API keys, hosting config). But buddy has financial profile data (risk tolerance, retirement targets) that's useful for goals and projections. **Keep Sure's settings infrastructure, port buddy's financial profile fields into Sure's user model.**

### 2.16 Scenarios & What-If (MIGRATE)

**Buddy app:**
- `/scenarios` — Scenario projections page
- `src/lib/yearly-forecasts/` — Forecast calculations, wealth metrics, scenarios
- Components: ScenarioProjectionCards, TrajectoryGauge, WealthMetricsCards, GoalCalculator, InsightsPanel, WhatIfSliders, FiftyThirtyTwentyChart
- Net worth projections, retirement calculators

**Sure:** Nothing like this.

**MIGRATE** — but as a later phase. Core budget views first.

### 2.17 Dashboard (BOTH — merge)

**Buddy app:**
- `/dashboard` — Main dashboard
- `/dashboard/index` and `/dashboard/health` sub-pages

**Sure:**
- Dashboard with account list, net worth chart, recent transactions, spending breakdown

**Keep Sure's dashboard, enhance with buddy's health metrics.**

---

## 3. SURE FEATURES — What We Haven't Accounted For

These are Sure features that weren't mentioned in the sprint doc and need to be preserved.

### 3.1 AI Chat Assistant (SURE ONLY — KEEP)
- Full chat interface with LLM integration (OpenAI, Ollama)
- Tool calling: get_accounts, get_balance_sheet, get_holdings, get_income_statement, get_transactions, import_bank_statement, search_family_files
- Chat history per user
- Configurable AI models and prompts in settings
- PDF import via AI extraction
- Document/vector store for searching uploaded files

**Status:** Not in sprint doc. **KEEP** — this is a valuable differentiator.

### 3.2 Reports Page (SURE ONLY — KEEP)
- Summary dashboard
- Net worth tracking
- Budget performance
- Transaction breakdown with CSV export
- Trends & insights
- Investment flows
- Investment performance
- Print-friendly layout
- Google Sheets integration (API key auth for export)
- Collapsible/reorderable sections with user preferences

**Status:** Not in sprint doc. **KEEP** — this is where buddy's spending/cash-flow analysis would merge.

### 3.3 Multi-Provider Bank Sync (SURE ONLY — KEEP)
Sure supports MANY bank sync providers:
- **Plaid** (US/Canada — 12,000+ institutions)
- **SimpleFin** (US alternative)
- **SnapTrade** (investment accounts)
- **Enable Banking** (Europe — PSD2)
- **Lunchflow** (additional provider)
- **Mercury** (business banking)
- **Coinbase** (crypto)
- **CoinStats** (crypto aggregator)
- **Indexa Capital** (European robo-advisor)

Each has its own account model, sync logic, and entry mapping.

**Status:** Not in sprint doc. **KEEP** — this is huge. Buddy only planned for Plaid.

### 3.4 Data Enrichment System (SURE ONLY — KEEP)
- Polymorphic enrichment tracking (which provider enriched which record)
- Sources: rule, plaid, simplefin, lunchflow, synth, ai, enable_banking, coinstats, mercury, indexa_capital
- Merchant matching from providers
- Transaction categorization from providers

**Status:** Not in sprint doc. **KEEP.**

### 3.5 Account Types (SURE > BUDDY)
Sure's account type system is richer:

| Sure Account Type | Classification | Buddy Equivalent |
|---|---|---|
| Depository (checking/savings) | Asset | checking, savings |
| Investment | Asset | investment, retirement_* |
| Crypto | Asset | (partial — in investments) |
| Property | Asset | real_estate (in assets table) |
| Vehicle | Asset | vehicle (in assets table) |
| OtherAsset | Asset | other asset types |
| CreditCard | Liability | credit_card |
| Loan | Liability | loan, mortgage |
| OtherLiability | Liability | (none) |

Sure also has **subtypes** per account type, and accounts have an AASM state machine (active, draft, disabled, pending_deletion).

**Status:** Partially in sprint doc. **KEEP Sure's** — it's more robust.

### 3.6 Entry System (SURE ONLY — KEEP)
Sure uses a polymorphic `Entry` model as the central journal:
- Types: Transaction, Valuation, Trade
- Every financial event is an Entry with date, amount, currency
- Entries belong to accounts
- This allows unified querying across transactions, valuations, and trades

**Status:** Not in sprint doc. **KEEP** — elegant architecture.

### 3.7 Family Export (SURE ONLY — KEEP)
- Export all family data as a downloadable archive
- Background job processing

**Status:** Not in sprint doc. **KEEP.**

### 3.8 Invitation System (SURE ONLY — KEEP)
- Invite family members via email
- Invite codes for households
- Multi-user per family

**Status:** Not in sprint doc. **KEEP** — essential for the household/family model.

### 3.9 Onboarding Wizard (SURE ONLY — KEEP)
- Guided setup for new users
- Account connection, category setup, initial budget

**Status:** Not in sprint doc. **KEEP.**

### 3.10 Self-Hosting Infrastructure (SURE ONLY — KEEP)
- Docker Compose deployment
- Settings for hosting configuration
- PWA manifest and service worker

**Status:** Not in sprint doc. **KEEP.**

---

## 4. UPDATED MIGRATION PRIORITY

Based on this full comparison, here's what needs to migrate, in priority order:

### MUST MIGRATE (Core to your vision)
1. **Budget views** — Daily/monthly/yearly with spreadsheet-style table (buddy's UI into Sure's data model)
2. **Savings-as-budget** — Inverted logic for savings categories + goal linking (NEW)
3. **Goals system** — Full goal schema with contributions, auto-tracking, linked accounts (buddy)
4. **Import system** — 10 institution presets, auto-detection, duplicate detection (buddy → Sure)
5. **Debt management** — Debts table, payoff projections, snowball/avalanche (buddy, Sure has nothing)
6. **Notifications** — Budget alerts, goal progress, bill reminders (buddy, Sure has nothing)
7. **Bills & Subscriptions** — Distinct from recurring transactions (buddy)

### SHOULD MIGRATE (High value)
8. **Spending/Cash Flow views** — Merge into Sure's reports page
9. **Investment portfolio views** — Screener, comparison, technical indicators (buddy → Sure's data infrastructure)
10. **Recurring transaction templates** — Buddy's template system into Sure's recurring model
11. **Smart rule enhancements** — Buddy's operators/actions into Sure's rule architecture
12. **Financial profile** — Risk tolerance, retirement planning fields (buddy → Sure's user model)
13. **Net worth health scoring** — Buddy's health page into Sure's dashboard

### CAN DEFER (Future sprints)
14. **Scenario projections / What-If** — Buddy's forecast tools
15. **Statements/reconciliation view** — Buddy's statement view
16. **Annual plan view** — The spreadsheet-inspired 12-month grid (NEW)
17. **Monthly vs non-monthly budget amounts** — Spreadsheet concept (NEW)
18. **Income by person/source** — Spreadsheet concept (NEW)
19. **Tax estimation** — Spreadsheet concept (NEW)

### KEEP FROM SURE (Don't lose these)
- AI Chat Assistant with tool calling
- Reports page with export + Google Sheets
- Multi-provider bank sync (9 providers)
- Data enrichment system
- Polymorphic Entry journal
- Family model with invitations
- Account type system with subtypes
- Onboarding wizard
- Self-hosting Docker infrastructure
- Family export
- MFA and SSO support
- API key management

---

## 5. Files Reference — Buddy App Complete Inventory

### Routes (38 top-level route groups)
```
/account          — Individual account detail
/accounts         — Account list & management
/api/*            — API endpoints (budgets, categories, etc.)
/assets           — Asset CRUD ($id, new, index)
/auth             — Authentication
/bills            — Bills tracking
/budget           — Budget views (daily, monthly, yearly, index)
/budget-analytics — Budget performance analytics
/budgets          — Budget CRUD ($id, new, index)
/cash-flow        — Cash flow analysis
/categories       — Category management
/dashboard        — Main dashboard + health
/debt             — Debt management
/goals            — Goals CRUD
/import           — CSV import wizard
/legal            — Legal pages
/merchants        — Merchant management
/net-worth        — Net worth + health scoring
/portfolio        — Investment portfolio (accounts, analytics, holdings, transactions)
/profile          — User profile
/recurring        — Recurring transactions (detect, history, templates)
/rules            — Smart rules engine
/scenarios        — Scenario projections
/security         — Security settings
/settings         — App settings
/spending         — Spending analysis
/statements       — Bank statement reconciliation
/stocks           — Stock screener & detail ($symbol, compare, screener)
/subscriptions    — Subscription tracking
/transactions     — Transaction list
/transfers        — Transfer management
/unified-transactions — Unified transaction view
```

### Database Schema (19 table files)
```
accounts.ts       — financialAccounts, accountBalanceHistory
assets.ts         — assets
budgets.ts        — budgets, budgetHistory
categories.ts     — categories
debts.ts          — debts
enums.ts          — 20+ enums
goals.ts          — goals, goalContributions, goalAutoTrackingRules, goalLinkedAccounts
investments.ts    — investmentHoldings, investmentTransactions, holdingLots
merchants.ts      — merchants, userMerchants
net-worth.ts      — netWorthSnapshots
notifications.ts  — notifications
plaid.ts          — plaidItems, plaidAccounts
rules.ts          — rules, ruleRuns
stocks.ts         — stocks, stockPriceHistory, watchlists, watchlistStocks
tags.ts           — tags, transactionTags
transactions.ts   — unifiedTransactions
transfers.ts      — transfers, rejectedTransfers
user-profiles.ts  — userProfiles, userSettings, userSessions
```

### Lib Modules (25 directories/files)
```
budget-forecasts/     — Forecast calculations
categories/           — Category service
email/                — Email integration
goals/                — Goal projections & optimization
import/               — Import system (CSVParser, ImportService, institutions)
merchants/            — Merchant service
middleware/            — Request middleware
net-worth/            — Net worth calculations
performance/          — Performance utilities
plaid/                — Plaid integration
portfolio-analytics/  — Portfolio performance calculations
queries/              — Shared database queries
quote-pricing.ts      — Stock quote API
recurring/            — Recurring detection
recurring-transactions/ — Recurring transaction management
rules/                — Rule engine service
sector-mapping.ts     — Financial sector mapping
security/             — Security utilities
server/               — Server functions
stock-api/            — Stock data API
stock-data.ts         — Stock data management
technical-indicators.ts — RSI, MACD, moving averages
transfers/            — Transfer detection service
unified-transactions/ — Unified transaction data access
validations/          — Input validation
yearly-forecasts/     — Yearly forecast/scenario calculations
```
