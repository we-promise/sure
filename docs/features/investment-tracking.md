# Investment Tracking

Sure provides features to help you track and manage your investment portfolio with accurate cost basis tracking and transaction classification.

## Cost Basis Tracking

Cost basis tracking helps you understand the original purchase price of your investments, which is essential for calculating returns and tax reporting.

### Cost Basis Sources

Sure tracks cost basis from three sources:

| Source | Description |
| --- | --- |
| **Manual** | User-entered values that you set directly |
| **Calculated** | Computed from your buy trades and transaction history |
| **Provider** | Imported from your financial institution (Plaid, SimpleFin, etc.) |

### Priority Hierarchy

When multiple sources provide cost basis data, Sure uses this priority:

**Manual > Calculated > Provider**

This means:
- Manual values always take precedence
- Calculated values override provider data
- Provider data is used when no other source is available

### Lock Protection

When you manually set a cost basis, Sure automatically locks it to prevent automatic updates from overwriting your value. This ensures your manual entries remain intact during account syncs.

### Setting Cost Basis Manually

You can set cost basis in two ways:

#### From the Holdings List

1. Navigate to your investment account
2. Find the holding in your portfolio
3. Click the pencil icon next to the average cost
4. Enter either:
   - **Total cost basis**: The total amount you paid for all shares
   - **Per-share cost**: The average price per share
5. The form automatically converts between total and per-share values
6. Click **Save**

The system will show a confirmation if you're overwriting an existing cost basis.

#### From the Holding Drawer

1. Click on a holding to open its detail drawer
2. In the Overview section, click the pencil icon next to "Average Cost"
3. Enter the cost basis (total or per-share)
4. Click **Save**

After saving, you'll see:
- A lock icon indicating the value is protected
- A source label showing "(manual)"

### Unlocking Cost Basis

If you want to allow automatic updates to recalculate your cost basis:

1. Open the holding drawer
2. Scroll to the **Settings** section
3. Find "Cost basis locked"
4. Click **Unlock**

After unlocking:
- The lock icon disappears
- Future syncs can update the cost basis
- Calculated values (from trades) will replace the manual value

### Bidirectional Conversion

The cost basis editor provides real-time conversion between total and per-share values:

- Enter total cost → automatically calculates per-share cost
- Enter per-share cost → automatically calculates total cost

This makes it easy to enter cost basis in whichever format you have available.

## Investment Activity Labels

Activity labels help you classify and understand investment transactions. They appear as badges in your transaction list and can be used to organize and filter your investment activity.

### Available Activity Types

Sure supports these investment activity labels:

| Label | Description |
| --- | --- |
| **Buy** | Purchase of securities |
| **Sell** | Sale of securities |
| **Contribution** | Money added to the investment account |
| **Withdrawal** | Money removed from the investment account |
| **Dividend** | Dividend payments received |
| **Interest** | Interest earned |
| **Reinvestment** | Dividends or distributions reinvested |
| **Sweep In** | Cash swept into the account |
| **Sweep Out** | Cash swept out of the account |
| **Fee** | Account or transaction fees |
| **Exchange** | Currency or security exchanges |
| **Transfer** | Transfers between accounts |
| **Other** | Miscellaneous transactions |

### Setting Activity Labels

You can set activity labels in two ways:

#### Manually for Individual Transactions

1. Open a transaction from an investment or crypto account
2. Scroll to the **Settings** section
3. Find "Activity type"
4. Select a label from the dropdown
5. The change saves automatically

#### Automatically with Rules

Create rules to automatically label transactions based on patterns:

1. Go to **Settings > Rules**
2. Create a new rule
3. Set conditions (e.g., "IF transaction name contains 'DIVIDEND'")
4. Add action: "Set investment activity label"
5. Choose the label (e.g., "Dividend")
6. Save the rule

Example rules:
- IF name contains "DIVIDEND" THEN set label to "Dividend"
- IF name contains "INTEREST" THEN set label to "Interest"
- IF name contains "FEE" THEN set label to "Fee"

Rules apply automatically to new transactions and can be run on existing transactions.

### Viewing Activity Labels

Activity labels appear as badges in:
- Transaction lists
- Transaction detail drawers
- Account activity views

They help you quickly identify the nature of each investment transaction without reading the full transaction name.
