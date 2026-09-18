# FinanceKit protocol 2 design record

Protocol 2 replaces the foreground-only draft from PR #3529. It keeps the parts that review established as safe: family/admin and preview gates, explicit mapping, complete typed validation, exact decimal money, deterministic sign normalization, disabled heuristic matching, same-ID pending transitions, protected-record checks, and explicit tombstones.

The foreground draft was not sufficient for an iOS publisher. It coupled collection to a live user request, treated device-local FinanceKit IDs as if one enrollment owned them forever, could not acknowledge work durably before canonical import, and had no ordered replay, replacement fence, repair generation, or visible conflict workflow.

Protocol 2 adds:

- a background-compatible one-purpose publisher credential;
- durable immutable batches and stable receipts;
- generation, stream, sequence, predecessor digest, capture, and chunk metadata;
- a contiguous inbox worker with bounded retry and explicit repair;
- stable family account lineages across device replacement;
- append-only balance observations;
- durable protected-entry conflicts and an authenticated resolution API; and
- separate receipt, import, and downstream health.

The earlier PR #3489 demonstrated useful durable-inbox and ordering concepts, but protocol 2 does not adopt its custom JOSE envelope. TLS already protects transport, Sure controls both endpoints, and envelope cryptography would add key rotation and recovery failure modes without protecting data after server acceptance. The design instead narrows credential authority, stores only its digest, redacts financial bodies, validates exact bytes before persistence, and deletes accepted payload bytes after a bounded replay window.

The protocol does not infer deletion from a snapshot, merge changed FinanceKit transaction UUIDs, or let a background credential read from Sure. Those choices preserve deterministic source identity and keep destructive reconciliation explicit.
