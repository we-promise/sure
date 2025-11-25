# Investment & Holdings Integration Assessment

> **Date**: November 2025
> **Status**: Analysis Complete - Ready for Implementation Planning

## Executive Summary

Investments and holdings in this application are architecturally sophisticated but operationally isolated. While the underlying data models (Holdings, Trades, Securities, Portfolio calculations) are well-designed, they exist in a parallel universe to the main financial reporting system. **When you buy an ETF, it doesn't register as an expense because trades bypass the transaction/category system entirely.**

---

## Current State Analysis

### What Works Well

| Feature | Status | Notes |
|---------|--------|-------|
| Net Worth | ✅ Included | Investment account balances appear in net worth |
| Holdings Tracking | ✅ Works | Quantities, prices, cost basis tracked correctly |
| Trade History | ✅ Works | Buy/sell/dividend trades recorded |
| Portfolio Performance | ✅ Partial | Unrealized gains shown on holdings page |
| Provider Sync | ✅ Works | Plaid/SimpleFin import holdings and trades |

### Critical Gaps

| Feature | Status | Impact |
|---------|--------|--------|
| Cashflow Integration | ❌ Missing | Buying stocks doesn't show as expense |
| Budget Tracking | ❌ Missing | Investment contributions invisible to budgets |
| Dashboard Visibility | ❌ Missing | No investment metrics on main dashboard |
| Reports Integration | ❌ Missing | No investment performance in reports |
| AI Assistant | ❌ Missing | Cannot answer portfolio questions |
| Category System | ❌ Missing | Trades have no categories |

---

## Root Cause Analysis

### 1. The Entry/Entryable Architecture Gap

The application uses a polymorphic `Entry` model with three entryable types:

```
Entry (entryable)
├── Transaction  → Has category_id, included in IncomeStatement
├── Trade        → No category_id, excluded from IncomeStatement
└── Valuation    → No category_id, excluded from IncomeStatement
```

**Problem**: `IncomeStatement` (the core of all financial reporting) only queries `Transaction` entries:

```ruby
# app/models/income_statement/totals.rb (lines ~20-30)
FROM transactions t
JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
```

Trades are structurally excluded from all cashflow/budget calculations.

### 2. Trade vs Transaction Conceptual Mismatch

**Current Design Philosophy**: Trades are investment operations, not expenses/income.

**User Expectation**: "I spent $5,000 buying VTSAX this month" should appear somewhere in expense tracking.

The application treats these as fundamentally different:
- **Transaction**: Money leaves → expense
- **Trade**: Money converts to securities → not an expense

Both are technically "cash outflows" but only one appears in financial reports.

### 3. Dashboard Architecture

**File**: `app/controllers/pages_controller.rb`

The dashboard queries:
- `balance_sheet` → includes investment balances ✅
- `income_statement` → excludes trades ❌
- No direct holdings/portfolio queries

### 4. AI Assistant Limitations

**File**: `app/models/assistant/configurable.rb`

Only 4 functions available:
- `get_transactions` - queries Transaction only
- `get_accounts` - includes investment accounts but not holdings
- `get_balance_sheet` - shows totals, not positions
- `get_income_statement` - excludes trades

No `get_holdings`, `get_portfolio`, or `get_investment_performance` functions.

---

## Proposed Improvements

### Tier 1: Quick Wins (Immediate Value)

#### 1.1 Add Investment Dashboard Widget

**Location**: `app/views/pages/dashboard/`

Create a new partial `_investment_summary.html.erb` showing:
- Total portfolio value (sum of investment account balances)
- Top 5 holdings by value
- Day/week/month change in portfolio value
- Quick link to detailed holdings view

**Implementation**:
```ruby
# app/controllers/pages_controller.rb
def dashboard
  # ... existing code ...
  @investment_accounts = Current.family.accounts.active.where(accountable_type: "Investment")
  @top_holdings = Holding.where(account: @investment_accounts)
                         .current_holdings
                         .order(amount: :desc)
                         .limit(5)
end
```

#### 1.2 Add Portfolio AI Function

**New file**: `app/models/assistant/function/get_portfolio.rb`

```ruby
class Assistant::Function::GetPortfolio < Assistant::Function
  def call
    holdings = family.accounts
                     .where(accountable_type: ["Investment", "Crypto"])
                     .flat_map(&:current_holdings)

    {
      total_value: holdings.sum(&:amount),
      holdings: holdings.map { |h| holding_data(h) },
      allocation: calculate_allocation(holdings),
      performance: calculate_performance(holdings)
    }
  end
end
```

#### 1.3 Investment Performance in Reports

**Location**: `app/views/reports/`

Add new section showing:
- Total investment contributions this period
- Unrealized gains/losses
- Realized gains (from sells)
- Dividend income

---

### Tier 2: Structural Improvements (Medium Effort)

#### 2.1 Investment Contribution Tracking

**Problem**: When money moves from checking to brokerage, it's a transfer. When that money buys stocks, it disappears from cashflow.

**Solution**: Create "Investment Contribution" as a trackable metric.

**Option A: Shadow Transactions**
- When a trade is created, optionally create a linked Transaction entry
- Transaction marked as `kind: :investment_contribution`
- Category: Auto-assigned "Investment Contributions"
- Appears in cashflow but can be filtered

**Option B: Parallel Tracking**
- Keep trades separate from transactions
- Create new `InvestmentStatement` model (parallel to `IncomeStatement`)
- Reports show both cash and investment flows

**Recommendation**: Option A is simpler and fits existing architecture.

**Implementation**:
```ruby
# app/models/trade.rb
after_create :create_shadow_transaction, if: :should_track_contribution?

def create_shadow_transaction
  return unless qty.positive? # Only buys

  Transaction.create!(
    entry_attributes: {
      account: entry.account,
      date: entry.date,
      amount: entry.amount,
      currency: entry.currency,
      name: "Investment: #{security.ticker}",
      linked_trade_id: id
    },
    kind: :investment_contribution,
    category: Category.investment_contributions
  )
end
```

#### 2.2 Enhanced Category System for Investments

**Current**: Trades have no categories.

**Proposed**: Add investment-specific categorization:

```ruby
# New categories (seeded)
- Investment Contributions
  - Retirement (401k, IRA)
  - Taxable Brokerage
  - Education (529)
- Investment Income
  - Dividends
  - Capital Gains (Realized)
  - Interest
```

**Schema change**:
```ruby
# Add to trades table
add_column :account_trades, :investment_category, :string
```

#### 2.3 Cashflow View Toggle

**Location**: `app/views/pages/dashboard/_cashflow_sankey.html.erb`

Add toggle: "Include Investment Flows"

When enabled:
- Buy trades appear as outflows to "Investment Contributions"
- Sell trades appear as inflows from "Investment Liquidations"
- Dividends appear as income

**Implementation**: Modify `IncomeStatement` to accept `include_investments: true` parameter.

---

### Tier 3: Deep Integration (Significant Effort)

#### 3.1 Unified Financial Statement

**Concept**: Merge `IncomeStatement` and investment flows into comprehensive view.

**New Model**: `CashflowStatement`

```ruby
class CashflowStatement
  def operating_activities
    # Regular income/expenses (current IncomeStatement)
  end

  def investing_activities
    # Buy/sell trades, dividends, capital gains
  end

  def financing_activities
    # Loan payments, credit card payments
  end

  def net_cash_flow
    operating + investing + financing
  end
end
```

This mirrors standard accounting cash flow statements.

#### 3.2 Investment Budget Category

**Allow budgeting for investments**:

```ruby
# app/models/budget.rb
def sync_budget_categories
  # Current: only expense categories
  # Proposed: include investment contribution category

  category_ids = family.categories.budgetable.pluck(:id)
  # Where budgetable includes expenses AND investment_contributions
end
```

Users could then:
- Set monthly investment goal: "$500 to retirement"
- Track actual contributions vs goal
- See investment contributions in budget progress

#### 3.3 Portfolio Analytics Dashboard

**New route**: `/portfolio`

**Features**:
- Asset allocation pie chart (stocks, bonds, cash, real estate)
- Sector breakdown
- Geographic distribution
- Performance vs benchmarks (S&P 500, etc.)
- Dividend income tracking
- Tax lot analysis
- Rebalancing suggestions

**Components needed**:
- `PortfolioController`
- `Portfolio::AllocationCalculator`
- `Portfolio::PerformanceCalculator`
- D3.js visualizations

#### 3.4 Realized Gains Tracking

**Current**: Only unrealized gains calculated.

**Needed**: Track realized gains when selling.

```ruby
# app/models/trade.rb
def calculate_realized_gain
  return nil unless qty.negative? # Only for sells

  # FIFO cost basis calculation
  cost_basis = calculate_fifo_cost_basis(security, qty.abs)
  proceeds = price * qty.abs

  proceeds - cost_basis
end
```

Store realized gains for tax reporting and performance tracking.

---

### Tier 4: Advanced Features (Future Vision)

#### 4.1 Tax-Loss Harvesting Alerts
- Identify holdings with losses
- Alert users to tax-loss harvesting opportunities
- Track wash sale rules

#### 4.2 Dividend Reinvestment Tracking
- DRIP detection and tracking
- Compound growth visualization

#### 4.3 Investment Goal Tracking
- "Retirement by 60" projections
- "House down payment" savings tracking
- Monte Carlo simulations

#### 4.4 Multi-Account Portfolio View
- Aggregate holdings across all investment accounts
- Household-level asset allocation
- Account-type optimization suggestions

---

## Implementation Roadmap

### Phase 1: Visibility
1. Dashboard investment widget
2. AI assistant `get_portfolio` function
3. Basic investment metrics in reports

### Phase 2: Tracking
1. Investment contribution shadow transactions
2. Investment categories
3. Cashflow toggle for investment flows

### Phase 3: Analysis
1. Portfolio analytics dashboard
2. Realized gains tracking
3. Performance vs benchmarks

### Phase 4: Planning
1. Investment budgeting
2. Goal tracking
3. Tax optimization features

---

## Key Files to Modify

| File | Change |
|------|--------|
| `app/models/income_statement.rb` | Add `include_investments` option |
| `app/models/income_statement/totals.rb` | Query trades when flag enabled |
| `app/controllers/pages_controller.rb` | Add investment data to dashboard |
| `app/views/pages/dashboard.html.erb` | Add investment widget |
| `app/models/assistant/configurable.rb` | Register new portfolio function |
| `app/models/trade.rb` | Add shadow transaction creation |
| `app/models/category.rb` | Add investment category types |
| `db/seeds/categories.rb` | Seed investment categories |
| `app/controllers/reports_controller.rb` | Add investment section |
| `config/routes.rb` | Add portfolio routes |

---

## Technical Architecture Reference

### Current Investment Models

```
Account (accountable_type: "Investment")
├── has_many :holdings
├── has_many :trades (through entries)
└── has_many :entries

Holding
├── belongs_to :account
├── belongs_to :security
├── qty, price, amount, currency, date
├── cost_basis
└── Methods: weight, avg_cost, trend, day_change

Trade (Entryable)
├── belongs_to :security
├── qty, price, currency
└── Methods: unrealized_gain_loss

Security
├── has_many :trades
├── has_many :prices
├── ticker, exchange_operating_mic, country_code
└── Methods: current_price

Entry
├── delegated_type :entryable (Transaction, Trade, Valuation)
├── account_id, date, amount, currency, name
└── Scopes: visible, chronological, in_period
```

### Balance Calculation Flow

```
Account Sync
└── Balance::Materializer
    ├── Holding::Materializer (calculates holdings)
    │   ├── ForwardCalculator (history → today)
    │   └── ReverseCalculator (today → history)
    └── Balance Calculator
        ├── For investment accounts:
        │   └── balance = cash_balance + holdings_value
        └── holdings_value = SUM(holding.amount)
```

### Income Statement Flow (Current - Excludes Investments)

```
IncomeStatement
├── Totals (SQL aggregation)
│   └── SELECT FROM transactions t
│       JOIN entries ae ON ae.entryable_type = 'Transaction'
│       WHERE t.kind NOT IN ('funds_movement', 'one_time', 'cc_payment')
├── CategoryStats
└── FamilyStats
```

---

## Summary

The current architecture treats investments as a separate financial domain that only intersects with the main application at the net worth level. To make investments first-class citizens, the application needs to:

1. **Bridge the Entry gap**: Allow trades to optionally create shadow transactions
2. **Extend reporting**: Include investment flows in cashflow/budget calculations
3. **Improve visibility**: Add investment metrics to dashboard and reports
4. **Enable AI**: Create portfolio-aware assistant functions
5. **Add analytics**: Build dedicated portfolio analysis features

The underlying investment infrastructure (Holdings, Trades, Securities, sync systems) is solid. The gap is in how this data flows into the user-facing financial analysis tools.
