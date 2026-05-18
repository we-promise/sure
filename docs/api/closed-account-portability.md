# Closed account portability behavior

Closed or disabled accounts are lifecycle state, not deletion. The account should stop normal sync/activity and can be hidden from default account lists, but the account and its historical ledger rows remain part of the family record.

## Account visibility

Default account navigation can focus on visible accounts. In the model layer, `Account.visible` means `draft` or `active`, so disabled accounts are intentionally omitted from default list-style views.

API and export surfaces that serve portability or audit workflows should expose lifecycle state instead of silently dropping the account:

| Surface | Behavior |
| --- | --- |
| Default account list | May hide disabled accounts by default. |
| `GET /api/v1/accounts` | Supports `include_disabled=true` to include disabled accounts while excluding accounts pending deletion. |
| `GET /api/v1/accounts/{id}` | Returns a disabled account only when `include_disabled=true` is provided; otherwise disabled and pending-deletion accounts return 404. |
| `GET /api/v1/balance_sheet` | Excludes disabled account balances by default and supports `include_disabled=true` for portability clients. |
| Family archive/export | Includes family accounts with their status metadata. |

`pending_deletion` is different from disabled. Pending deletion is an in-progress destructive state and should not be treated as a normal closed-account archive state.

## Ledger inclusion

Transactions, trades, balances, holdings, valuations, transfers, rejected transfers, and referenced securities attached to a disabled account are still historical facts. Portability and audit surfaces should not apply the default account-list visibility rule to ledger history.

Use these rules when changing transaction/search/export/report behavior:

- Account-list visibility decides whether an account appears in default navigation.
- Ledger inclusion decides whether historical rows remain queryable, searchable, reportable, and exportable.
- Closing an account should not erase historical rows from global transaction history, search, reports, or migration/export surfaces.
- If an endpoint intentionally hides disabled-account data, the endpoint should expose an explicit inclusion parameter and document the default.
- Net worth history should include disabled accounts so closing an account does not create a false historical gain or loss when balances were moved elsewhere.

## Migration and archive expectations

Portable exports should preserve:

- account ID, name, type, subtype, status, currency, and balance metadata;
- all historical transactions and other ledger rows scoped to the family;
- transfer and rejected-transfer relationships only when both transaction sides are exported;
- account state separately from whether rows are included in the archive.

Importers should restore the account lifecycle state without treating disabled accounts as deleted. Restored historical rows should stay attached to the restored account even when the account remains disabled.

## Sync behavior

Closed or disabled accounts should not start new provider sync activity by default. Provider-specific syncers may still keep diagnostic/status records, but they should not turn disabled-account visibility into ledger deletion.
