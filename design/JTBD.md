# Jobs to Be Done (JTBD) Framework

This document outlines the critical Jobs to Be Done for `Sure`, a self-hosted personal finance and wealth management platform.

---

## Tier 1: Core/Essential Jobs

### 1. "Help me see my complete financial picture in one place"

**Job:** Aggregate all financial accounts (bank, credit, investments, crypto, property, loans) across multiple institutions.

**Evidence:**
- Dashboard with net worth, balance sheet, income/expense statements
- 8+ account types supported (depository, credit, investments, crypto, loans, properties, vehicles, other assets/liabilities)
- Multi-provider integrations (Plaid, SimpleFIN, Enable Banking, Coinbase, Mercury, SnapTrade, CoinStats, Lunchflow)

**Outcome:** Eliminates fragmented views across different bank apps and spreadsheets.

---

### 2. "Help me understand where my money is going"

**Job:** Track and categorize transactions to reveal spending patterns.

**Evidence:**
- Hierarchical category system with parent/child relationships
- Merchant linking and tagging
- Transaction search and filtering with multiple criteria
- Bulk transaction operations

**Outcome:** Transform raw transactions into actionable spending insights.

---

### 3. "Keep my accounts up-to-date automatically"

**Job:** Sync financial data from institutions without manual entry.

**Evidence:**
- 9+ provider integrations (Plaid, SimpleFIN, Enable Banking, Coinbase, Mercury, SnapTrade, CoinStats, Lunchflow)
- Background sync jobs via Sidekiq
- Pending transaction detection and reconciliation
- Sync status tracking with error handling

**Outcome:** Eliminates the burden of manual data entry.

---

### 4. "Help me track my investment performance"

**Job:** Monitor holdings, trades, cost basis, and gains/losses across investment accounts.

**Evidence:**
- Holdings with quantity, price, amount, and cost basis tracking
- Trade management (buy/sell/dividend/reinvestment/sweep/exchange)
- 40+ investment account subtypes with tax treatment classification
- Unrealized and realized gain/loss calculations
- Securities with current prices and market data

**Outcome:** Clear visibility into portfolio performance and tax implications.

---

## Tier 2: High-Value Jobs

### 5. "Help me stay within my spending limits"

**Job:** Set and track budgets against actual spending.

**Evidence:**
- Monthly budget creation with budgeted spending and expected income
- Per-category budget tracking
- Calculations: actual_spending, available_to_spend, available_to_allocate
- Visual progress indicators

**Outcome:** Proactive spending control rather than reactive review.

---

### 6. "Help me plan for recurring expenses and income"

**Job:** Forecast cash flow based on recurring patterns.

**Evidence:**
- Recurring transaction tracking with next_expected_date
- Active/inactive recurring transaction status
- Projected upcoming transactions (next 10 days)

**Outcome:** Anticipate future cash position.

---

### 7. "Let me bring in my existing financial data"

**Job:** Import data from CSV files, PDFs, and other formats.

**Evidence:**
- CSV imports for transactions, trades, accounts, categories, rules
- PDF statement imports with AI extraction
- Mint export support
- Custom field mapping and transformation rules
- Import status tracking and reversion capability

**Outcome:** Flexibility to consolidate historical data.

---

### 8. "Automatically organize my transactions"

**Job:** Apply rules to categorize and manage transactions as they arrive.

**Evidence:**
- Rule engine with conditions and actions
- Rules applied based on merchant, amount, account filters
- Rule execution history tracking
- Affected resource counting

**Outcome:** Reduce manual categorization work.

---

## Tier 3: Enabling Jobs

### 9. "Let my family collaborate on our finances"

**Job:** Share financial data and collaborate on budgeting with family members.

**Evidence:**
- Family model as organizational unit
- Multiple users per family with roles (member, admin, super_admin)
- Invitations system for adding family members
- Shared accounts, categories, budgets, and transaction data

**Outcome:** Unified family financial management.

---

### 10. "Keep my financial data private and secure"

**Job:** Maintain security and data ownership.

**Evidence:**
- Self-hosted deployment option
- MFA with OTP and backup codes
- ActiveRecord encryption for sensitive PII
- API key authentication with scopes
- Rate limiting via Rack Attack
- OAuth2 support for third-party apps

**Outcome:** Control over sensitive financial data (key differentiator vs. SaaS alternatives).

---

## The "Why" Behind These Jobs

| Pain Point | JTBD That Solves It |
|------------|---------------------|
| Accounts scattered across 10+ institutions | #1 - Aggregate all data |
| No idea where $500/month is leaking | #2 - Track spending |
| Manual entry takes hours weekly | #3 - Auto-sync |
| Don't know if investments are up or down | #4 - Track performance |
| Overspending discovered after the fact | #5 - Budget management |
| Don't trust cloud services with finances | #10 - Self-hosted security |

---

## User Types and Primary Jobs

| User Type | Primary Jobs |
|-----------|--------------|
| General Personal Finance Users | #1, #2, #3, #5 |
| Active Investors | #1, #4, #7 |
| Crypto Enthusiasts | #1, #4, #7 |
| Families/Couples | #1, #2, #3, #9 |
| Wealth Builders | #1, #2, #4, #5 |
| Data Privacy Advocates | #1, #3, #10 |

---

## The Foundational Job

The single most critical JTBD is:

> **"When I want to understand my true financial position, help me see all my money across all accounts in one trusted place, so I can make informed decisions about my financial future."**

This is the foundational job that enables all others. Everything else (budgeting, investment tracking, reporting) depends on first having a complete, accurate, and up-to-date view of all financial accounts.
