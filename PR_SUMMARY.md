# Imports API Implementation

## Overview
This PR implements the `Api::V1::ImportsController`, allowing external applications to programmatically import financial transactions via CSV. It provides endpoints to create, list, and retrieve imports, with support for automatic processing and rule application.

It also adds a Drag-and-Drop feature to the Transactions page and the Import Upload page for easier CSV uploading.

## Key Features

### 1. New API Endpoints
- **`GET /api/v1/imports`**: List all imports for the user's family with pagination and filtering.
- **`GET /api/v1/imports/{id}`**: Retrieve detailed information about a specific import, including configuration and row statistics.
- **`POST /api/v1/imports`**: Create a new import from raw CSV content.

### 2. Automatic Processing
- **Row Generation**: When a CSV is uploaded via the API, import rows are automatically generated and validated.
- **Auto-Publish**: Clients can pass `publish: true` to automatically queue the import for processing (creation of transactions) immediately after creation.
- **Rule Application**: Publishing an import triggers the family sync process, which automatically applies all user-defined rules (categorization, tagging, etc.) to the new transactions.

### 3. Smart Import Logic
- **Account Mapping**: Supports both a single `account_id` for the entire file or a dynamic `account_col_label` for multi-account CSVs.
- **Duplicate Detection**: Uses `Account::ProviderImportAdapter` to identify and update existing transactions instead of creating duplicates.
- **Category Mapping**: Automatically matches CSV category names to existing family categories.

### 4. UI Enhancements
- **Drag & Drop Import**:
  - Added a full-screen drag-and-drop overlay to the **Transactions** list. Dropping a CSV file starts a new import.
  - Added full-screen drag-and-drop support to the **Import Upload** page (`/imports/:id/upload`). Dropping a file populates the "Upload CSV" form and submits it.

## Performance Optimizations
- **N+1 Query Fix**: Implemented a `counter_cache` for `Import#rows`.
  - Added `rows_count` column to `imports` table.
  - Updated `Import::Row` to use `counter_cache: true`.
  - Optimized API views and models to use the `rows_count` attribute, avoiding expensive per-import row count queries in the `index` action.
- **Preloading**: Preloaded `rows` in the `show` action to efficiently calculate valid row counts.

## Security & Validation
- **Family Scoping**: Added `account_belongs_to_family` validation to the `Import` model to prevent users from importing data into accounts they do not own.
- **Scope Verification**: Endpoints require `read` or `read_write` OAuth scopes.
- **Mass Assignment Protection**: Explicitly handled `type` and `account_id` in the controller instead of using strong parameters for these sensitive attributes, and added validation to ensure only allowed STI types can be instantiated.
- **File Validation**: Enforced size limits (10MB) and MIME type checks for uploaded CSV files to prevent memory exhaustion and invalid file processing.

## Documentation
- Added `docs/api/imports.md` with detailed usage instructions, authentication requirements, and example payloads.

## Testing
- Added `test/controllers/api/v1/imports_controller_test.rb` covering:
  - Authorization and scoping.
  - Successful import creation and row generation.
  - Auto-publish functionality.
  - Cross-family account access prevention (Security).
  - Categorized and bulk imports.
- Added `test/system/drag_and_drop_import_test.rb` covering the new UI feature.
- Verified all tests pass.
