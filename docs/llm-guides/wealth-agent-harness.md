# Wealth history with an external agent harness

How to run a provenance-first wealth model — one where every number walks
back to the document it came from — on top of Sure, without putting that model
inside Sure.

The model itself is specified by
[the wealth + tax blueprint](wealth-blueprint.md). This guide is the seam:
which half owns what, which MCP tool serves which layer of the blueprint, and
which invariants Sure cannot enforce for you.

## The two-install shape

**Sure** is the system of record. Accounts, values and statement documents live
here, and the agent's job against Sure is to keep them clean, complete and
cited.

**The harness** is your own repository, driven by an agent (OpenClaw, Claude
Code, anything that speaks MCP). It holds the wealth + tax memory: the position
catalog, the tax criteria, the numbered-delta compiler, the golden tests and
the compiled workbook. It reads and writes Sure over `/mcp`.

```text
   your repo (the harness)                         Sure
   ───────────────────────                         ────
   catalogs/ positions, criteria, FX    ──MCP──►   accounts, entries, valuations
   tax_data/*.jsonl                                Statement Vault (documents + sha256)
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
| L1 positions, parameters, FX table, tax criteria | **Harness** | — |
| L2 wealth series | **Sure** is authoritative | `Entry` / `Valuation`, `Holding`. The harness snapshots it into `data/YYYY-MM/*.csv` so `git diff` and the goldens have something to bite on. |
| L2 tax series — criterion, `applicable`, `declared`, `legal_max` | **Harness only** | Sure has one value per account per date. "One value, one criterion" (§2 principle 6) has no representation here and should not be forced into one. |
| L3 vault — account statements | **Split** | Sure's **Statement Vault** is the shared archive: original bytes in storage, SHA-256 dedup, period detection, account matching, review queue. But it never hands bytes back over MCP, so the harness must keep its own copy of any statement it intends to extract from. See "The harness keeps the parseable master" below. |
| L3 vault — tax returns, annual accounts, capital accounts, contracts, minutes, email | **Harness** | The Statement Vault is statement-shaped and accepts PDF/CSV/XLSX only. Keep other primary sources in the harness's own git-ignored vault. |
| `_control.csv` / reconcile-or-abort | **Split** | Sure's `get_account_statement` reports *ledger-agreement* checks (statement balances vs the ledger, tolerance 0.01, report-only). The blueprint's *parse-integrity* check (parts vs the document's own printed total) and the **abort** have no counterpart in Sure — keep both in the harness extractor. |
| Gap map / `PENDING` policy | **Sure** | `get_statement_coverage` reports covered / missing / mismatched / ambiguous per month. |
| Numbered deltas, goldens, workbook, divergences report | **Harness only** | — |

### Three invariants Sure cannot give you

- **Closed periods are immutable** (§2 principle 7). A Postgres row is mutable
  and keeps no history you can diff. Immutability lives in the harness snapshot
  and its commits.
- **Golden tests** (§14). Same reason: pin row counts and snapshot totals in the
  harness, against the snapshot, not against a live query.
- **Reconcile-or-abort as a hard gate** (§2 principle 3, §7 pass 3). Sure's
  `get_account_statement` reports *statement-vs-ledger* agreement and never
  aborts; it does **not** check the blueprint's *parse-integrity* invariant
  (parsed parts summing to the document's own printed total), and its tolerance
  is a fixed 0.01, not the blueprint's 1.00-per-account-period gate. Both that
  check and the abort belong to the harness extractor. See the vocabulary map.

Treat Sure as a source you re-derive from, not as the archive of what you
already derived.

## The harness keeps the parseable master

**Sure never returns a document's bytes over MCP, by design.** Stored files are
served only to a signed-in browser session (Active Storage authorization checks
`viewable_by?(Current.user)`), and an MCP client holds a bearer token, not a
session. Nor is there a text fallback: statements archived through
`upload_account_statement` do not enter the vector store, so
`search_family_files` cannot see them either. To an agent, a statement in Sure is
metadata — identity, period, account, coverage, ledger reconciliation — and
nothing more.

That matters because the blueprint needs the bytes for three things, all of them
operating on bank and broker statements: the §9 extractors, the §7 pass-3
parse-integrity check, and the §9.2 glyph decoder. Everything else the blueprint
parses — tax returns, capital accounts, annual accounts — the harness already
holds locally, per the ownership table.

**So parse first, publish second.** The extractor runs on the harness's own copy,
where the bytes are; Sure receives the archived copy afterwards:

1. The document lands in the **harness's** inbox.
2. The harness's `vault_ops` ingests it into the harness vault — canonical name,
   SHA-256, manifest, human OK (§8.1–8.3).
3. **The extractor parses it there**, with the whole file: labelled subtotals,
   glyph decoding where needed, reconcile-or-abort against the printed total.
4. The harness publishes a copy to Sure with `upload_account_statement`.
5. The harness records values with `record_valuation`, citing that SHA-256.
6. Sure supplies what the harness cannot: ledger reconciliation, the coverage
   map, the review and linking UI, and the household's shared archive.

This ordering *restores* §2 principle 8 rather than bending it. The principle
says the recurring pipeline reads exclusively from the canonical store — and
treating Sure as canonical would force a re-fetch the architecture never
sanctioned. The harness vault is canonical; Sure is where you publish.

**The SHA-256 is the join key, and it removes the need to move bytes at all.**
Both sides hash the same file independently, so
`list_account_statements(content_sha256: …)` *verifies* that Sure holds the
identical document. That is §8.2's "same content = same hash regardless of name"
applied across a system boundary.

Two consequences worth stating plainly rather than discovering later:

- A statement someone uploads straight into Sure's web UI, which the harness
  never saw, can be **known but not parsed**. You get its period, account,
  coverage and ledger reconciliation; you cannot extract from it. Per §13 any
  value derived from it is reliability C, or stays `PENDING`, until a copy
  reaches the harness inbox.
- **Neither vault backs up the other.** Sure cannot rebuild the harness's data
  layer, and the harness cannot rebuild Sure's archive.

## The tools

These are preview features. Enable them per user in **Settings → Preferences**;
until then they do not appear in `tools/list` and calling one by name returns
"Unknown tool". The MCP user must also be an admin or member — the Statement
Vault is closed to guests, over MCP exactly as in the UI.

| Tool | Use it for |
|---|---|
| `upload_account_statement` | Ingest a statement (PDF/CSV/XLSX, ≤25 MB, base64). Returns the SHA-256. Re-uploading identical bytes returns the existing record with `duplicate: true` — dedup is free and idempotent, so a re-run is safe. |
| `list_account_statements` | The vault index and the review queue. Filter by account, period, `review_status`, or `content_sha256` to check whether a document is already archived. |
| `get_account_statement` | One document: identity, the balances **recorded for it** (user-entered in Settings → Statement Vault, not auto-extracted — blank until filled), and the reconciliation checks against the ledger *when balances exist*. Returns no bytes and no link — see "The harness keeps the parseable master". |
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
| `_control.csv` official total | `opening_balance` / `closing_balance` — **user-entered** fields (Settings → Statement Vault), not auto-extracted on upload; blank until a human fills them, so reconciliation is `unavailable` over MCP until then |
| reconcile-or-abort (§7 pass 3) | **no direct equivalent** — `reconciliation_checks` gives statement-vs-ledger agreement (tolerance 0.01, report-only, `matched` / `mismatched`); it does not sum parsed parts against the document's printed total, and never aborts. Parse-integrity + abort stay harness-side |
| gap policy `PENDING` (§13) | coverage status `missing` |
| reliability grade (§13.4) | the `(grade: A\|B\|C)` suffix on `record_valuation`'s `source` |

## The monthly runbook, against Sure

Blueprint §15.2, rewritten:

1. **Ingest and extract, harness-side first.** New documents land in the
   harness's inbox, go through its own `vault_ops` (canonical name, SHA-256,
   manifest, human OK), and are parsed *there* — reconcile-or-abort against the
   printed total, while the bytes are still in reach. Only then publish each one
   to Sure with `upload_account_statement`. A `duplicate: true` response means it
   was already archived: a normal outcome, not an error, and confirmation that
   both sides hold the same file. Publishing before extracting strands you —
   Sure will not hand the bytes back.
2. **Hand off the match.** Report each unmatched statement and its suggested
   account to the user; they confirm in Settings → Statement Vault. Do not
   proceed as if the link exists.
3. **Reconcile.** `get_account_statement` on each new statement. Reconciliation
   only runs once the statement's `opening_balance` / `closing_balance` are
   filled — these are user-entered in Settings → Statement Vault, not
   auto-extracted, so an agent-only pipeline gets `reconciliation_status:
   "unavailable"` here until a human enters them. When a check does run, a
   `mismatched` result means the ledger and the document disagree — stop and
   report it. Never adjust the figure to make it agree. (This is
   statement-vs-ledger agreement; the blueprint's parts-vs-printed-total
   parse-integrity check and its abort are the harness extractor's job.)
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
- **Phase 6 (the vault)** — **partly already built**. Sure gives you archival,
  SHA-256 dedup, the review queue and the coverage map for account statements,
  so don't rebuild those. You still need a harness-side vault for every document
  the extractors read — statements included, since Sure won't return their bytes
  — plus the non-statement sources it was never going to hold.
- **Phase 7 (the tax layer)** — entirely harness-side. Sure has no criterion
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

- [The wealth + tax blueprint](wealth-blueprint.md) — the full spec.
- [MCP Server for External AI Assistants](../hosting/mcp.md) — endpoint,
  authentication, tool list.
- [External AI Assistant configuration](../hosting/ai.md#openclaw-gateway-example)
  — pointing OpenClaw at Sure.
- [Gating a preview feature](gating-a-preview-feature.md) — the toggle these
  tools sit behind.
