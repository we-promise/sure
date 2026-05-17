# BankData Import API

The BankData import API accepts Excel-categorized transactions from the BankData Python pipeline and imports them append-only into Sure.

## Authentication

Send an API key with write scope using `X-Api-Key`.

## Preview

`POST /api/v1/bankdata/imports/preview`

Preview validates the payload and returns the same reconciliation shape as import without creating or modifying entries.

## Import

`POST /api/v1/bankdata/imports`

Import creates only missing transactions. Rows whose `external_id` already exists for the mapped account and `source = bankdata_pipeline` are returned as `already_imported` and are not overwritten.

## Payload Notes

- `source` must be `bankdata_pipeline`.
- `allow_uncategorized: true` imports rows without `category_name` so Sure Rules can categorize them after import.
- `account_mappings` maps BankData `Type rekening` values to Sure account IDs.
- `transactions[].external_id` must be stable and unique in the request.
- `transactions[].amount` uses Sure sign convention: expenses positive, income negative.
- `transactions[].extra.bankdata_pipeline` preserves Excel audit metadata.

## SQL Import Mode

Use `allow_uncategorized: true` for periodic MariaDB imports where rows do not yet have mapped categories. Sure imports the transactions append-only and leaves `category_name` blank so active Sure Rules can categorize them after import.

Use the default `allow_uncategorized: false` for Excel bootstrap imports where every imported row should already have a trusted category. Rows without `category_name` are reported as `uncategorized` in preview/import summaries and are not created unless the flag is enabled.

## Summary

Responses include aggregate counts, income/expense totals, and per-row `items` with `status` and optional `reason`.
