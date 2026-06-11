# India Tax Workbook Import Design

## Context

Sure already has family-scoped imports, settings pages, Active Storage attachments, and a Statement Vault that accepts PDF, CSV, and XLSX uploads for account statements. It does not currently parse spreadsheet workbooks into tax records, and the existing import workflow is oriented around financial accounts, transactions, merchants, rules, and Sure NDJSON imports.

The requested feature is for Indian monthly GST and TDS calculations that are already maintained in Excel or Google Sheets. Users should be able to upload a workbook, have Sure parse it into structured records, then list, search, and report those records inside the app.

Research was delegated to a data researcher agent. The research used official GST Portal, CBIC, Income Tax Department, TRACES/Protean-oriented sources, and identified one important scope boundary: the workbook is an internal calculation and reporting format. It is not itself a statutory filing output. GST filing uses GST portal return flows and offline utilities, while e-TDS/e-TCS filing expects text files prepared to official file formats and validated through the RPU/FVU process.

## Goals

- Add a dedicated Tax Calculations area in Settings for India GST/TDS workbook uploads.
- Parse uploaded `.xlsx` workbooks into structured GST and TDS records.
- Provide a downloadable example/template workbook with India-compliance-oriented tabs and columns.
- Validate required tabs, required columns, identifier formats, enum values, and numeric/date fields before committing parsed rows.
- Store upload history, source file, validation status, row counts, and parser errors.
- Let users list and search imported tax records by period, GSTIN, TAN, PAN, section/table code, party, invoice, challan, and amount.
- Provide monthly GST summaries and monthly-to-quarterly TDS summaries for internal reporting.

## Non-Goals

- Do not generate or submit statutory GST return JSON files.
- Do not generate e-TDS/e-TCS `.txt` files, `.fvu` files, Form 26Q filings, or TRACES submissions.
- Do not support every TDS form in the first slice. Start with non-salary Form 26Q-style records.
- Do not infer GST/TDS calculations from Sure transactions in the first slice.
- Do not support arbitrary user-designed spreadsheets in the first slice. Users should upload the Sure template shape.
- Do not add accounting advice or claim the app has verified filing readiness.

## Access And Placement

Add a Settings navigation item named "Tax Calculations" for admin users. This should use the same settings layout pattern as Statement Vault, Imports, and Exports.

The feature is scoped to `Current.family`. All tax workbook imports and parsed records belong to the current family. A user who can administer the family can upload, view, download, and delete tax workbook imports.

## Workbook Format

The app should publish a normalized workbook template with these tabs:

- `meta`
- `gst_outward_lines`
- `gst_3b_summary`
- `gst_hsn_summary`
- `tds_deductions`
- `tds_challans`

The parser should accept the tabs in any order but require exact normalized tab names. Headers should be matched case-insensitively after trimming whitespace and converting spaces/hyphens to underscores.

### `meta`

One row per upload batch:

- `entity_name`
- `gstin`
- `tan`
- `fy`
- `tax_period_month`
- `tax_period_quarter`
- `return_type`
- `source_system`
- `source_file_name`

`tax_period_month` is required for GST records. `tax_period_quarter` is required for TDS reporting. If both GST and TDS tabs are present, both fields should be present.

### `gst_outward_lines`

One row per invoice, credit note, debit note, or adjustment:

- `gstr1_table_code`
- `invoice_no`
- `invoice_date`
- `recipient_gstin_or_uin`
- `place_of_supply_state`
- `hsn_code`
- `rate_pct`
- `taxable_value`
- `igst`
- `cgst`
- `sgst_ugst`
- `cess`
- `is_reverse_charge`
- `is_export`
- `is_ecommerce_tcs`
- `is_credit_note`
- `is_debit_note`

This tab supports line-level drill-down and monthly GST outward-supply reports.

### `gst_3b_summary`

One row per GSTR-3B summary bucket:

- `section_code`
- `taxable_value`
- `igst`
- `cgst`
- `sgst_ugst`
- `cess`
- `interest`
- `late_fee`

Supported initial `section_code` values:

- `3.1(a)`
- `3.1(d)`
- `3.1.1`
- `3.2`
- `4`
- `5`
- `5.1`
- `6.1`

This tab should be stored separately from `gst_outward_lines` because GSTR-3B is a return-period summary, not an invoice ledger.

### `gst_hsn_summary`

One row per HSN/SAC reporting bucket:

- `hsn_code`
- `description`
- `uqc`
- `quantity`
- `taxable_value`
- `igst`
- `cgst`
- `sgst_ugst`
- `cess`
- `bucket`

Supported initial `bucket` values:

- `B2B`
- `B2C`

### `tds_deductions`

One row per payment or deduction event:

- `deductor_tan`
- `deductee_pan_or_aadhaar`
- `deductee_name`
- `section_code`
- `booking_date`
- `payment_date`
- `amount_paid`
- `tds_rate_pct`
- `tds_amount`
- `surcharge`
- `cess`
- `challan_ref`
- `resident_status`

Supported initial `section_code` values:

- `192A`
- `193`
- `194`
- `194A`
- `194B`
- `194BA`
- `194BB`
- `194C`
- `194D`
- `194DA`
- `194EE`
- `194F`
- `194G`
- `194H`
- `194I`
- `194J`
- `194K`
- `194LA`
- `194LBA`
- `194LBB`
- `194LBC`
- `194N`
- `194O`
- `194P`
- `194Q`
- `194R`
- `194S`

Reject `194-IA` in this import path because that belongs to a separate Form 26QB flow.

### `tds_challans`

One row per challan or book-adjustment record:

- `challan_ref`
- `mode_of_deposit`
- `bsr_code_or_receipt_no`
- `challan_serial_no_or_ddo_serial_no`
- `deposit_date`
- `minor_head`
- `tax`
- `interest`
- `fee`
- `penalty`
- `others`
- `total_amount`

`challan_ref` links deductions to challans inside Sure. The first slice should validate that every non-empty `tds_deductions.challan_ref` exists in `tds_challans`.

## Data Model

Create a `TaxWorkbookImport` model:

- `family_id`
- `uploaded_by_id`
- `status`: `pending`, `validated`, `importing`, `complete`, `failed`
- `filename`
- `content_type`
- `byte_size`
- `checksum`
- `template_version`
- `entity_name`
- `gstin`
- `tan`
- `fy`
- `tax_period_month`
- `tax_period_quarter`
- `row_counts`
- `validation_errors`
- `metadata`
- `has_one_attached :source_file`

Create parsed-record models:

- `GstOutwardLine`
- `Gst3bSummary`
- `GstHsnSummary`
- `TdsDeduction`
- `TdsChallan`

Each parsed-record model belongs to `family` and `tax_workbook_import`. Store money-like values as decimals with enough precision for rupee amounts and paise-level fractions. Store tax percentages as decimals. Store source row numbers for every parsed row so validation errors and UI records can point back to the workbook row.

## Parsing And Validation

Add an XLSX parser dependency during implementation. The plan should verify the current stable Ruby XLSX parsing option before changing the Gemfile. `roo` is the likely starting point because this is read-only workbook parsing, but the implementation plan must confirm the current maintained choice.

The parser should:

1. Open `.xlsx` files only.
2. Reject empty files and files above the configured upload limit.
3. Read workbook sheets and normalize sheet/header names.
4. Parse `meta` first.
5. Validate all required tabs and headers.
6. Parse date, boolean, decimal, identifier, and enum values into typed row objects.
7. Collect all row-level validation errors without committing partial parsed records.
8. Commit records only when the whole workbook passes validation.

Identifier validation:

- GSTIN: 15-character alphanumeric format, with state-code prefix retained as text.
- TAN: 10-character alphanumeric format.
- PAN: 10-character alphanumeric format when provided as PAN.

Numeric validation:

- Amount fields must parse as decimals.
- Tax component totals should not be negative unless the row is marked as a credit note, debit note, amendment, or supported adjustment.
- `igst` should not be combined with `cgst`/`sgst_ugst` on the same ordinary GST line unless explicitly allowed by a supported adjustment type.
- `tds_challans.total_amount` should equal `tax + interest + fee + penalty + others`.

Period validation:

- `tax_period_month` should normalize to the first day of the month.
- `tax_period_quarter` should normalize to an Indian financial-year quarter.
- TDS deduction dates should fall inside the workbook quarter unless an explicit future exception is designed.

## User Workflow

1. User opens Settings -> Tax Calculations.
2. User downloads the example workbook template or uploads an existing template-shaped `.xlsx`.
3. App validates the workbook.
4. If validation fails, app shows tab, row number, column, provided value, and error message.
5. If validation passes, app imports parsed records and shows an import summary.
6. User can view import history, download the source workbook, delete an import, or search parsed records.
7. User can open reports for GST monthly summary and TDS monthly/quarterly summary.

## Listing, Search, And Reports

The Tax Calculations index should show upload history and high-level totals:

- Period
- Entity
- GSTIN
- TAN
- GST outward taxable value
- GST tax total
- TDS amount total
- Status
- Uploaded by
- Uploaded at

Search filters should include:

- Month
- Quarter
- Entity name
- GSTIN
- TAN
- PAN
- GST table/section code
- TDS section code
- Invoice number
- Challan reference
- Amount range

GST monthly reports should aggregate by:

- `tax_period_month`
- `gstin`
- `gstr1_table_code`
- `rate_pct`
- `place_of_supply_state`
- `hsn_code`

TDS reports should aggregate by:

- Month
- Financial-year quarter
- TAN
- Section code
- Deductee PAN
- Challan reference

## Error Handling

Validation errors should be non-destructive. A failed upload should keep the original file and validation errors on `TaxWorkbookImport`, but should not create parsed records.

Import replacement should be explicit. If the user uploads a second workbook for the same entity, GSTIN/TAN, and period, the app should warn about the existing import and require replacing it or keeping both. The first slice can keep both and make duplicates visible; replacement can be added after the reporting screens prove the workflow.

Deletion should remove parsed records and purge the source file through normal Active Storage cleanup.

## Testing

Model tests should cover:

- workbook metadata validation
- required sheet/header validation
- GST row parsing
- TDS row parsing
- challan reference validation
- duplicate-period behavior
- invalid identifier and decimal errors

Controller tests should cover:

- admin access
- non-admin denial
- successful upload
- failed validation upload
- source-file download authorization
- listing and search filters

System tests should cover the happy path:

- visit Tax Calculations
- upload sample workbook
- see parsed GST/TDS totals
- search by invoice or PAN

## Official Reference Set

Use these references for implementation-time validation details:

- GST Portal GSTR-3B guide: `https://tutorial.gst.gov.in/userguide/returns/Create_and_Submit_GSTR3B.htm`
- GST Portal GSTR-3B FAQ: `https://tutorial.gst.gov.in/userguide/returns/GSTR3B.htm`
- GST Portal returns help: `https://www.gst.gov.in/help/returns`
- CBIC Rule 46 tax invoice particulars: `https://taxinformation.cbic.gov.in/content/html/tax_repository/gst/rules/cgst_rules/active/chapter6/rule46_v1.00.html`
- Income Tax Department online TDS return filing: `https://www.incometaxindia.gov.in/tax-services/file-tds-return`
- Protean e-TDS/TCS return preparation page: `https://tinpan.proteantech.in/downloads/e-tds/eTDS-download-regular.html`
- Form 26Q official PDF: `https://contents.tdscpc.gov.in/forms/Form%2026Q.pdf`

## Risks And Follow-Up

The workbook schema should be reviewed by a CA before production filing decisions depend on it. India GST/TDS forms, HSN validation rules, section applicability, and filing utilities can change.

If users later need statutory output, design separate exporters for GST portal JSON/offline utility flows and e-TDS `.txt`/FVU flows. Those should be explicit filing features, not hidden inside the internal workbook parser.

