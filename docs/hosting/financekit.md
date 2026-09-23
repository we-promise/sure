# Operating the FinanceKit background publisher

FinanceKit is default-off and requires:

- `FINANCEKIT_ENABLED=true`;
- `FINANCEKIT_FAMILY_IDS`, a comma-separated exact family UUID allowlist;
- an active enrolling family administrator with preview features enabled; and
- the scheduled `FinancekitInboxJob` sweep in addition to jobs enqueued when a batch arrives.

No Apple Wallet entitlement, private key, or FinanceKit framework is installed on the server. Sure never receives the user's Apple credentials. The iOS app obtains Wallet authorization directly from Apple and uploads only the accounts the user selected and consented to share.

## Deployment

Deploy the migration, application, worker, and scheduler with the feature flag disabled. The migration introduces publisher connections, stable account lineages, immutable batch receipts, source transaction identities, balance observations, and conflicts.

After deploy:

1. Confirm the high-priority job queue and recurring scheduler are healthy.
2. Enable only a disposable test family.
3. Enroll and activate a synthetic publisher over HTTPS.
4. Upload sequences 2 then 1 and confirm the inbox applies them in order.
5. Retry identical bytes and confirm the receipt is stable and no ledger row duplicates.
6. Rotate the credential and confirm the prior credential cannot upload or call normal APIs.
7. Replace the publisher and confirm the canonical account, source identities, and tombstones are reused.
8. Induce a bad predecessor and confirm the connection enters `repair_required`; repair must create a new generation and stream.
9. Confirm health reports device contact, acceptance, import, and downstream completion separately.
10. Confirm applied, permanently failed, and revoked payload bytes are removed after seven days.

Monitor queue depth, oldest accepted batch age, `repair_required` connections, and downstream lag. Diagnostics may include publisher, batch, sequence, generation, and typed error codes. They must not include credentials, raw request bodies, transaction descriptions, merchant names, amounts, account names, or server authentication headers.

## Capacity and retention

Protocol 2 limits each publisher to 20 selected accounts, 500 events per batch, 1 MiB of JSON, and 100 accepted/processing batches. Each capture is limited to 100 chunks so the complete capture fits in the inbox. A client can upload larger histories using multiple consecutive captures.

Exact payload bytes are retained for seven days after apply, permanent failure, or revocation for response-loss recovery and operational investigation. Canonical financial data and source identity records follow Sure's normal family retention and deletion behavior. Family financial-data reset removes FinanceKit connections, lineages, observations, identities, conflicts, and batch receipts for that family.

## Rollback

Disable `FINANCEKIT_ENABLED` first. Existing Sure data remains readable, uploads return a retryable unavailable response, and workers stop applying FinanceKit batches. Do not drop the tables during an application rollback; keep receipts and lineage data until all deployed versions no longer reference them and the retention decision is explicit.
