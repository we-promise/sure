Mercury (Direct API) integration

Overview
- This integration uses a generalized bank provider layer (BankConnection/BankExternalAccount) so additional banks can be added with minimal code.

Setup
- API base URL: defaults to `https://api.mercury.com` (override via `MERCURY_API_BASE_URL`).
- Credentials required when creating a connection:
  - `api_key`: Your Mercury API key (Bearer token).
  - Optional `webhook_signing_secret`: If set, incoming webhook signatures will be verified.

Endpoints used
- Accounts: `GET /api/v1/accounts` (response includes `accounts: [...]`).
- Transactions: `GET /api/v1/account/:id/transactions`.
  - Pagination: `limit` (defaulted to 500 in our client), `offset`, and optional `order` (e.g., `desc`).
  - Filtering: Mercury docs highlight `requestId` for correlation; no date range query params are documented for this endpoint.

Webhooks
- Endpoint in Sure: `POST /webhooks/banks/mercury`.
- Our verifier currently supports HMAC-SHA256 of `{timestamp}.{raw_body}` and accepts either hex or base64 signatures.
- Headers used by our verifier: `X-Mercury-Signature` and `X-Mercury-Timestamp`.
- If Mercury's official webhook header names or signing scheme differ, update `Provider::Banks::Mercury#verify_webhook_signature!` accordingly and adjust tests.

Notes
- The code tolerates arrays or wrapped payloads (e.g., `{accounts: [...]}`, `{transactions: [...]}`, `{data: [...]}`) and follows cursors or next URLs.
- If Mercury’s docs differ for header names, param names, or pagination shape, update `Provider::Banks::Mercury` accordingly.
