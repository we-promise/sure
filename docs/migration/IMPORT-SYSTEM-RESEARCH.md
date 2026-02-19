# Sure Finance Import System — Deep Dive Research

> **Date:** 2026-02-19
> **Context:** Reviewing Sure's import system as reference for the holistic financial planner fork
> **Source repo:** https://github.com/we-promise/sure

---

## 1. Import Flow Overview (5-Step Wizard)

Sure uses a multi-step wizard with a progress nav bar at the top. The steps are:

```
Upload → Configure → Clean → Map → Confirm/Import
```

PDF imports have a simplified flow: `Upload → Clean → Confirm` (configuration is handled by AI extraction).

The nav bar (`imports/_nav.html.erb`) shows numbered circles with green checkmarks for completed steps. Each step is a separate route with its own controller.

### Routes

| Step | Route | Controller |
|------|-------|------------|
| Upload | `GET /imports/:id/upload` | `Import::UploadsController#show` |
| Configure | `GET /imports/:id/configuration` | `Import::ConfigurationsController#show` |
| Clean | `GET /imports/:id/clean` | `Import::CleansController#show` |
| Map/Confirm | `GET /imports/:id/confirm` | `Import::ConfirmsController#show` |
| Final | `GET /imports/:id` | `ImportsController#show` |

---

## 2. Step 1: Upload

**File:** `app/views/import/uploads/show.html.erb`

Two input methods via tabs:

### CSV File Upload
- Drag & drop zone (264px tall dashed border area)
- Browse button to select file
- Column separator selection (comma, semicolon, tab)
- Optional: pre-select an account for transaction/trade imports
- Drag & drop overlay (`_drag_drop_overlay.html.erb`) appears when dragging files over the page

### Copy & Paste
- Text area for pasting CSV content directly
- Same separator and account options

### Constraints
- Max CSV size: 10MB (`Import::MAX_CSV_SIZE`)
- Max row count: 10,000 (`max_row_count`)
- Allowed MIME types validated
- PDF files detected by `%PDF-` header magic bytes
- Sample CSV download link provided

### Resume Support
- If a pending import exists, shows a "Resume [Type]" option at the top of the new import dialog with an orange loader icon

---

## 3. Step 2: Configure

**File:** `app/views/import/configurations/show.html.erb`
**Type-specific partial:** `_transaction_import.html.erb`

### Template Detection
If a previous import from the same account exists, Sure offers to auto-apply that column mapping:
```
"We found a configuration from a previous import for this account.
Would you like to apply it to this import?"
[Manually configure] [Apply template]
```
This reduces friction for recurring imports (e.g., monthly bank statement downloads).

### Sample Data Preview
Shows a table of the first few CSV rows so the user can see what they're mapping.

### Transaction Import Configuration Fields

1. **Rows to skip** — Number field. For CSVs with extra header rows or metadata at the top.

2. **Date column + Date format** — Two side-by-side selects. Date column picks from CSV headers. Format picks from `Family::DATE_FORMATS`.

3. **Amount column + Currency column + Number format** — Three fields in a row:
   - Amount: required, picks from CSV headers
   - Currency: optional (defaults to family currency), picks from CSV headers
   - Number format: required. Options from `Import::NUMBER_FORMATS`:
     - US: `1,234.56`
     - EU: `1.234,56`
     - French: `1 234,56`

4. **Amount type strategy** — How to determine income vs expense:
   - `signed_amount`: Positive/negative numbers. Reveals sub-field:
     - Signage convention: "Incomes are positive" or "Incomes are negative"
   - `custom_column`: A separate CSV column determines type. Reveals cascading sub-fields:
     - Select the type column from CSV headers
     - Select the identifier value (populated from unique values in that column)
     - Specify what that value means: "Income (inflow)" or "Expense (outflow)"

5. **Optional fields** — All select from CSV headers, all have "Leave empty" option:
   - Account (hidden if account was pre-selected during upload)
   - Name
   - Category
   - Tags
   - Notes

### Configuration Controller
On submit, `ConfigurationsController#update`:
1. Saves the column mapping to the import record
2. Calls `@import.generate_rows_from_csv` — parses CSV into `Import::Row` records
3. Calls `@import.reload.sync_mappings` — creates `Import::Mapping` records for unique values
4. Redirects to the Clean step

---

## 4. Step 3: Clean (The "Missing Field Dialog")

**File:** `app/views/import/cleans/show.html.erb`
**Row form:** `app/views/import/rows/_form.html.erb`

This is the standout feature. It shows every imported row in a **spreadsheet-style inline-editable grid**.

### Layout
```
┌─────────────────────────────────────────────────────────┐
│              Clean your data                             │
│    Edit any rows that have errors below                  │
│                                                          │
│  ⚠ You have X rows with errors  [All rows] [Error rows] │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ DATE       │ AMOUNT    │ NAME        │ CATEGORY     │ │
│  ├────────────┼───────────┼─────────────┼──────────────┤ │
│  │ 2026-01-15 │ 45.99     │ Grocery St  │ Groceries    │ │
│  │ [RED]      │ [RED]     │ Gas Station │              │ │ ← error cells highlighted
│  │ 2026-01-17 │ 1800.00   │ Rent        │ Housing      │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─────── Pagination ─────────┐                          │
│  │  ◄  1  2  3  4  5  ►      │                          │
│  └────────────────────────────┘                          │
└─────────────────────────────────────────────────────────┘
```

### How Inline Editing Works

Each cell is a **Turbo Frame** wrapping a form:

```erb
<%= turbo_frame_tag dom_id(row, key) do %>
  <%= form_with model: [row.import, row], url: import_row_path(...), method: :patch,
      data: { controller: "auto-submit-form", auto_submit_form_trigger_value: "blur" } do |form| %>
    <%= form.text_field key, class: cell_class(row, key) %>
  <% end %>
<% end %>
```

- **Auto-submit on blur**: When you tab away from a cell, the form submits via Turbo
- **Per-cell Turbo Frame**: Only the edited cell re-renders, not the entire page
- **Validation feedback**: Invalid cells get red background via `cell_class` helper
- **Error tooltips**: Invalid cells show an alert-circle icon. On mobile, tapping it toggles an error tooltip

### Error Row Filtering

Toggle between "All rows" and "Error rows":
- "All rows": shows every imported row
- "Error rows": `rows.reject { |row| row.valid? }` — only rows with validation errors

### Status States

- **Not cleaned** (has errors): Red warning banner with error count + row toggle
- **Cleaned** (all valid): Green success banner with "Next step" button

### Pagination
- Default 10 rows per page
- Fixed pagination bar at bottom of viewport
- `per_page` parameter in URL

### Mobile Handling
- `mobile-cell-interaction` Stimulus controller handles touch events
- Cells get a highlight overlay on focus
- Error tooltips positioned above the cell
- Grid is horizontally scrollable with `overflow-x-auto`

---

## 5. Step 4: Map (Confirm Mappings)

**File:** `app/views/import/confirms/show.html.erb` + `_mappings.html.erb`

### Multi-Step Mapping

For transaction imports, there are 3 mapping sub-steps (shown as progress dots):
1. **Category Mapping** — map CSV category values → Sure categories
2. **Tag Mapping** — map CSV tag values → Sure tags
3. **Account Mapping** — map CSV account values → Sure accounts

Each step shows a 3-column grid:

```
┌──────────────────────────────────────────────────────┐
│  CSV Category    │  Sure Category     │  Rows        │
├──────────────────┼────────────────────┼──────────────┤
│  "Groceries"     │  [Groceries    ▼]  │  42          │
│  "Eating Out"    │  [Dining Out   ▼]  │  28          │
│  "Gas"           │  [Select...    ▼]  │  15          │
│  "(unassigned)"  │  [Leave empty  ▼]  │  3           │
└──────────────────────────────────────────────────────┘
                  [Next →]
```

### Mapping Dropdown Options
- **Existing objects**: All categories/tags/accounts in the family
- **"Create new"**: `CREATE_NEW_KEY` option — auto-creates the object during import
- **"Leave unassigned"**: Skip mapping for this value
- **"Select an option"**: Required selection (for accounts when `requires_selection?`)

### Special Account Mapping Handling
- **No accounts exist**: Red banner — "You need to create an account" with link to account creation
- **Unassigned accounts**: Yellow warning — "Some transactions don't have an account assigned"
- Both link to `new_account_path` in a modal frame

### Auto-Submit
Each mapping form auto-submits on dropdown change via `auto-submit-form` Stimulus controller.

### Import::Mapping Model
```ruby
# Polymorphic: maps CSV values to app objects
class Import::Mapping
  belongs_to :import
  belongs_to :mappable, polymorphic: true, optional: true

  # Scopes
  scope :categories  # type = "Import::CategoryMapping"
  scope :tags        # type = "Import::TagMapping"
  scope :accounts    # type = "Import::AccountMapping"

  # Key methods
  selectable_values    # dropdown options for this mapping type
  requires_selection?  # must user pick something?
  create_when_empty?   # will auto-create if no match?
  values_count         # how many CSV rows use this value
end
```

---

## 6. Step 5: Final Confirm & Import

**File:** `app/views/imports/show.html.erb`
**Controller:** `ImportsController#show`

### Pre-flight Checks
- If not uploaded → redirect to upload step
- If not publishable → redirect to confirm step
- Shows final summary before execution

### Import Execution
- `@import.publish_later` — enqueues a Sidekiq background job
- Processes all rows, creates records (transactions, trades, accounts, etc.)
- Max row count checked: raises `Import::MaxRowCountExceededError` if exceeded

### Post-Import
- Import marked as `complete` on success, `failed` on error
- **Revert**: Can undo the entire import (`@import.revert_later`) — also a background job
- **Delete**: Destroys the import record and all associated data

---

## 7. Import Types Supported

| Type | Icon | Color | Required Columns | Optional Columns | Mapping Steps |
|------|------|-------|------------------|------------------|---------------|
| TransactionImport | file-spreadsheet | indigo | date, amount | name, currency, category, tags, notes, account | Category, Tag, Account |
| TradeImport | square-percent | yellow | date, qty, ticker, price | currency, account, exchange_operating_mic | Account |
| AccountImport | building | violet | name, balance | currency, type | (none) |
| CategoryImport | shapes | blue | name | color, classification, parent, icon | (none) |
| RuleImport | workflow | green | (varies) | | (none) |
| MintImport | Mint logo | — | date, amount (Mint CSV format) | | Category, Tag, Account |
| PdfImport | file-text | red | PDF file | | AI extracts → clean → confirm |
| DocumentImport | file-text | red | any supported doc | | VectorStore integration |

---

## 8. Key Design Patterns

### 8.1 Template Reuse
When importing from the same account again, Sure remembers the previous column mapping configuration and offers to apply it automatically. This is stored on the import record and detected via `suggested_template`.

### 8.2 Inline Cell Editing (Turbo Frames)
The clean step uses one Turbo Frame per cell. Editing a cell submits just that cell's form, and only that cell re-renders. No full page reload, no JavaScript framework needed — pure server-rendered HTML with Turbo.

### 8.3 Progressive Disclosure
The amount type strategy uses cascading reveals:
- Select "signed_amount" → shows signage convention
- Select "custom_column" → shows column picker → shows value picker → shows type selector
Each subsequent field only appears after the previous is answered.

### 8.4 Error-First Workflow
The "Error rows" toggle in the clean step lets users focus exclusively on problems. This is much better than scrolling through hundreds of valid rows to find the few broken ones.

### 8.5 Polymorphic Mappings
One `Import::Mapping` model handles category, tag, and account mappings with the same UI pattern. STI subclasses (`Import::CategoryMapping`, `Import::TagMapping`, `Import::AccountMapping`) each know their own selectable values and validation rules.

### 8.6 Background Processing
Both `publish` (execute import) and `revert` (undo import) run as background Sidekiq jobs. Large imports don't block the UI. The user sees a "processing" state and can check back.

### 8.7 Multi-Format Support
- **Number formats**: US (1,234.56), EU (1.234,56), French (1 234,56)
- **Date formats**: Pulled from `Family::DATE_FORMATS`
- **Signage conventions**: Incomes positive vs incomes negative
- **Column separators**: Comma, semicolon, tab
- **Encoding detection**: Handles various CSV encodings

### 8.8 Duplicate Detection
`TransactionImport` uses `Account::ProviderImportAdapter` to detect potential duplicate transactions during import, preventing double-entry.

---

## 9. Gaps for the Holistic Financial Planner Vision

### Missing Import Types Needed
1. **BudgetImport** — Import a budget plan (monthly/annual allocations per category). Would need: category, monthly amount, non-monthly amount, frequency.
2. **IncomeSourceImport** — Import income sources by person. Would need: person, source name, source type, gross amount, net amount, frequency.
3. **DebtImport** — Import debt accounts with balances, rates, minimum payments.
4. **GoalImport** — Import financial goals with targets and timelines.

### Missing Features
1. **No recurring transaction detection** — Import treats each row as a one-time event. No pattern detection for "this $1,800 appears monthly, mark as recurring."
2. **No multi-sheet support** — CSV only (single table). The personal spreadsheet has income on left + expenses on right. Would need to split or restructure for import.
3. **No budget variance import** — Can't import historical over/under data per category per month.
4. **No tax data import** — No way to import W-2 data, withholdings, or estimated payments.
5. **Max 10,000 rows** — Hardcoded limit. Fine for transaction history but could limit years of data.
6. **No scheduled/recurring import** — Each import is manual. No "auto-import from this bank every week."

### What Works Well (Keep/Extend)
1. **The clean step (missing field dialog)** — Inline spreadsheet editing with error highlighting is excellent UX
2. **Template reuse** — Remembering column mappings saves time on recurring imports
3. **Mapping wizard** — Mapping CSV values to app objects with "Create new" option is very user-friendly
4. **Multi-format number parsing** — Essential for international users
5. **Background processing with revert** — Safe, non-blocking, undoable imports
6. **Drag & drop + paste** — Two convenient input methods

---

## 10. Import System File Index

### Models
- `app/models/import.rb` — Base STI class (408 lines). CSV parsing, column mapping, row generation, encoding detection, state management.
- `app/models/transaction_import.rb` — Transaction CSV subclass. Required: date, amount. Maps categories, tags, accounts.
- `app/models/trade_import.rb` — Trade/investment CSV subclass.
- `app/models/account_import.rb` — Account CSV subclass.
- `app/models/category_import.rb` — Category CSV subclass.
- `app/models/rule_import.rb` — Rule CSV subclass.
- `app/models/mint_import.rb` — Mint-formatted CSV subclass.
- `app/models/pdf_import.rb` — PDF AI-extraction subclass.
- `app/models/import/mapping.rb` — Polymorphic mapping (CSV value → app object).
- `app/models/import/row.rb` — Individual parsed CSV row with validation.

### Controllers
- `app/controllers/imports_controller.rb` — CRUD: create, show, update, publish, revert, destroy, apply_template.
- `app/controllers/import/uploads_controller.rb` — Upload step.
- `app/controllers/import/configurations_controller.rb` — Column mapping configuration step.
- `app/controllers/import/cleans_controller.rb` — Data cleaning step (error row filtering, pagination).
- `app/controllers/import/confirms_controller.rb` — Mapping confirmation step.
- `app/controllers/import/rows_controller.rb` — Individual row editing (update single cells).
- `app/controllers/import/mappings_controller.rb` — Mapping CRUD.

### Views
- `app/views/imports/new.html.erb` — Import type selection dialog.
- `app/views/imports/_import_option.html.erb` — Import type list item.
- `app/views/imports/_drag_drop_overlay.html.erb` — Drag & drop overlay.
- `app/views/imports/_nav.html.erb` — Step progress nav bar.
- `app/views/imports/_table.html.erb` — Sample data preview table.
- `app/views/import/uploads/show.html.erb` — Upload step (file upload + paste tabs).
- `app/views/import/configurations/show.html.erb` — Configuration step (template detection + column mapping).
- `app/views/import/configurations/_transaction_import.html.erb` — Transaction-specific column mapping form.
- `app/views/import/cleans/show.html.erb` — Clean step (inline spreadsheet editor).
- `app/views/import/rows/_form.html.erb` — Per-row inline form (Turbo Frame cells).
- `app/views/import/rows/show.html.erb` — Single row view.
- `app/views/import/confirms/show.html.erb` — Mapping confirmation wizard.
- `app/views/import/confirms/_mappings.html.erb` — Mapping grid (CSV value → app object).
- `app/views/import/mappings/_form.html.erb` — Individual mapping dropdown form.

### Stimulus Controllers (JavaScript)
- `auto-submit-form` — Auto-submits forms on blur/change events.
- `drag-and-drop-import` — Handles file drag & drop overlay.
- `file-upload` — Manages file input UI (file name display, click-to-browse).
- `import` — Configuration page interactions (cascading selects for amount type strategy).
- `mobile-cell-interaction` — Mobile touch handling for clean step cells (highlight, error tooltips).
