# Patrimonial history with an external agent harness

How to run a provenance-first patrimonial model — one where every number walks
back to the document it came from — on top of Sure, without putting that model
inside Sure.

The model itself is specified by
[the patrimonial blueprint](patrimonial-blueprint.md). This guide is the seam:
which half owns what, which MCP tool serves which layer of the blueprint, and
which invariants Sure cannot enforce for you.

## The two-install shape

**Sure** is the system of record. Accounts, values and statement documents live
here, and the agent's job against Sure is to keep them clean, complete and
cited.

**The harness** is your own repository, driven by an agent (OpenClaw, Claude
Code, anything that speaks MCP). It holds the patrimonial memory: the position
catalog, the fiscal criteria, the numbered-delta compiler, the golden tests and
the compiled workbook. It reads and writes Sure over `/mcp`.

```text
   your repo (the harness)                         Sure
   ───────────────────────                         ────
   catalogs/ positions, criteria, FX    ──MCP──►   accounts, entries, valuations
   fiscal_data/*.jsonl                             Statement Vault (documents + sha256)
   data/YYYY-MM/*.csv  (snapshot)       ◄─MCP───   coverage + reconciliation checks
   src/NNN_*.py  → workbook.xlsx
   tests/  goldens
```

Sure is deliberately not the compiler. The blueprint's §2 principle 1 — the
workbook is a build output regenerated from source — only works if the source is
versioned, diffable and immutable once closed. That is what your git repo is
for.

## Who owns which layer

| Blueprint layer | Owner | In Sure |
|---|---|---|
| L0/L1 entities, holders | Sure, partially | `Family`, `User`, `accounts.owner_id`. Holders that are not Sure users — a holding company, a trust — have no home here; keep them in the harness's entity registry. |
| L1 account registry | **Sure** | `Account` + its `accountable`. Off-bank positions model well as `OtherAsset` or `Property` accounts. |
| L1 positions, parameters, FX table, fiscal criteria | **Harness** | — |
| L2 patrimonial series | **Sure** is authoritative | `Entry` / `Valuation`, `Holding`. The harness snapshots it into `data/YYYY-MM/*.csv` so `git diff` and the goldens have something to bite on. |
| L2 fiscal series — criterion, `applicable`, `declared`, `legal_max` | **Harness only** | Sure has one value per account per date. "One value, one criterion" (§2 principle 6) has no representation here and should not be forced into one. |
| L3 vault — account statements | **Sure** | The **Statement Vault**: original bytes in storage, SHA-256 dedup, period detection, account matching, review queue. |
| L3 vault — tax returns, annual accounts, capital accounts, contracts, minutes, email | **Harness** | The Statement Vault is statement-shaped and accepts PDF/CSV/XLSX only. Keep other primary sources in the harness's own git-ignored vault. |
| `_control.csv` / reconcile-or-abort | **Sure** | `get_account_statement` returns reconciliation checks against the ledger. |
| Gap map / `PENDING` policy | **Sure** | `get_statement_coverage` reports covered / missing / mismatched / ambiguous per month. |
| Numbered deltas, goldens, workbook, divergences report | **Harness only** | — |

### Two invariants Sure cannot give you

- **Closed periods are immutable** (§2 principle 7). A Postgres row is mutable
  and keeps no history you can diff. Immutability lives in the harness snapshot
  and its commits.
- **Golden tests** (§14). Same reason: pin row counts and snapshot totals in the
  harness, against the snapshot, not against a live query.

Treat Sure as a source you re-derive from, not as the archive of what you
already derived.

## The tools

These are preview features. Enable them per user in **Settings → Preferences**;
until then they do not appear in `tools/list` and calling one by name returns
"Unknown tool". The MCP user must also be an admin or member — the Statement
Vault is closed to guests, over MCP exactly as in the UI.

| Tool | Use it for |
|---|---|
| `upload_account_statement` | Ingest a statement (PDF/CSV/XLSX, ≤25 MB, base64). Returns the SHA-256. Re-uploading identical bytes returns the existing record with `duplicate: true` — dedup is free and idempotent, so a re-run is safe. |
| `list_account_statements` | The vault index and the review queue. Filter by account, period, `review_status`, or `content_sha256` to check whether a document is already archived. |
| `get_account_statement` | One document: identity, the balances read off it, the reconciliation checks against the ledger, and a 15-minute download URL. |
| `get_statement_coverage` | The month-by-month gap map for an account: `covered`, `missing`, `mismatched`, `ambiguous`, `duplicate`, `not_expected`. |
| `record_valuation` | Write a value for a date, with a mandatory citation. |
| `search_family_files` | Semantic search inside uploaded documents (needs a vector store configured). Complements the vault: identity from `list_account_statements`, contents from here. |
| `get_accounts`, `get_holdings`, `get_balance_sheet`, `get_transactions` | Pulling L1/L2 into the harness snapshot. |

### The citation grammar

`record_valuation` requires a `source` and parses it. This is the one place Sure
can enforce §2 principle 2 — never invent a datum — so it fails loud rather than
storing an uncited number:

```text
source := ["estimated: "] citation [" (grade: A|B|C)"]
```

- `A` — an official document for that exact date.
- `B` — derived with a document.
- `C` — a proxy or assumption: a standing TODO to re-derive from the real source.
- `estimated: ` — interpolated or proxied rather than read off a document.
  Estimates must carry a grade.

Valid:

```text
Private bank statement 2026-03-31, securities subtotal (grade: A)
estimated: linear interpolation over 2024-08 / 2024-12 anchors (grade: C)
```

Rejected: a blank citation, `(grade: D)`, `Estimated:` with a capital E, and an
`estimated:` value with no grade. The citation is stored on the entry's notes,
so it travels with the value and shows in the UI.

### What the agent does not get to do

`link` and `reject` are **not** exposed. Attaching a statement to an account is
the human sign-off step of §8.3, and §17 keeps external actions with the owner.
Sure already proposes a match — `suggested_account` with a confidence score,
computed at upload — and the user confirms it in Settings → Statement Vault.

Report the suggestion. Do not describe a suggested match as a link.

## Vocabulary map

Reading the blueprint against this codebase:

| Blueprint | Sure |
|---|---|
| `{inbox}` / staging inbox | statements with `review_status: "unmatched"` |
| triage (mechanical-first) | `AccountStatement::MetadataDetector` — period, institution, last-4 from filename and contents |
| triage proposal | `AccountStatement::AccountMatcher` → `suggested_account` + `match_confidence` |
| dry-run manifest + human OK (§8.3) | the link/reject step in Settings → Statement Vault |
| sha256 index (§8.2) | `account_statements.content_sha256`, unique per family |
| `TOKEN_YYYY-MM-DD_Title.ext` (§8.1) | not enforced; the SHA-256 is the stable identifier, and filenames are free text |
| `_control.csv` official total | `opening_balance` / `closing_balance` read off the statement |
| reconcile-or-abort (§7 pass 3) | `reconciliation_checks`, tolerance 0.01, reported as `matched` / `mismatched` |
| gap policy `PENDING` (§13) | coverage status `missing` |
| reliability grade (§13.4) | the `(grade: A\|B\|C)` suffix on `record_valuation`'s `source` |

## The monthly runbook, against Sure

Blueprint §15.2, rewritten:

1. **Ingest.** `upload_account_statement` for each new document. A `duplicate:
   true` response means it was already archived — that is a normal outcome, not
   an error.
2. **Hand off the match.** Report each unmatched statement and its suggested
   account to the user; they confirm in Settings → Statement Vault. Do not
   proceed as if the link exists.
3. **Reconcile.** `get_account_statement` on each new statement. A `mismatched`
   check means the ledger and the document disagree — stop and report it. Never
   adjust the figure to make it agree.
4. **Close the gaps.** `get_statement_coverage` per account for the year. Every
   `missing` month is either a document to go find or an explicit `PENDING` in
   the harness — never a silently interpolated number.
5. **Value the off-bank positions.** `record_valuation` with a citation, one per
   position that moved.
6. **Snapshot.** Pull L1/L2 into `data/YYYY-MM/*.csv` with the byte-stable
   writer. A no-op re-run must produce an empty `git diff`.
7. **Goldens.** Run them. When a count moves, update the constant *with its
   one-line justification*.
8. **Build.** Regenerate the workbook, recalc, confirm zero formula errors.
9. **Commit** the snapshot, the golden update, and the working-memory sync in one
   commit naming the period and the reconciliation result.

## Building the harness: the phases, remapped

Blueprint §20 assumes you build everything. Against Sure, several phases are
already done:

- **Phase 0 (map the sources)** — unchanged, and still the phase people skip.
  `list_account_statements` and `get_statement_coverage` give you the inventory
  for anything already in Sure.
- **Phase 1 (catalogs, schemas, skeleton)** — build the harness's schemas and
  the snapshot writer. The account registry comes from `get_accounts` instead of
  being hand-curated; keep the positions catalog local.
- **Phases 2–4 (extractors)** — mostly replaced. Sure's provider syncs and
  statement parsing already produce L2. The harness's "extractor" is a
  `pull_from_sure` step writing the snapshot. Write extractors only for source
  families Sure does not handle.
- **Phase 5 (views)** — unchanged, harness-side.
- **Phase 6 (the vault)** — **already built** for account statements. Do not
  rebuild it. Build only the vault for non-statement sources.
- **Phase 7 (fiscal layer)** — entirely harness-side. Sure has no criterion
  dimension and should not grow one.
- **Phase 8 (forensics, intel, agent memory)** — entirely harness-side. Email
  sweeps never touch Sure; facts they establish enter as an
  `upload_account_statement` (if a document backs them) plus a
  `record_valuation` citing it.

## Known gaps

Worth knowing before you promise the user something:

- **Non-user holders.** Sure's holder concept is a `User` in a `Family`. A
  holding company as a first-class holder needs the harness's own registry, with
  its Sure accounts mapped to it.
- **Non-statement documents.** PDF/CSV/XLSX statements only. Tax returns and
  capital accounts can be uploaded if they fit those formats, but the vault will
  treat them as statements — period detection and account matching will produce
  noise. Prefer the harness's own vault for those.
- **One value per account per date.** Storing two criteria for the same position
  and date, exactly one applicable, is the harness's job.
- **Statement periods are detected, not guaranteed.** `MetadataDetector` reads
  them from the filename and contents; check `period_start_on` / `period_end_on`
  on the upload response before relying on coverage.

## See also

- [The patrimonial blueprint](patrimonial-blueprint.md) — the full spec.
- [MCP Server for External AI Assistants](../hosting/mcp.md) — endpoint,
  authentication, tool list.
- [External AI Assistant configuration](../hosting/ai.md#openclaw-gateway-example)
  — pointing OpenClaw at Sure.
- [Gating a preview feature](gating-a-preview-feature.md) — the toggle these
  tools sit behind.
