# Proposal v0.8: AI / ML workflows

Working documents for discussing how Sure's AI and ML features should evolve towards v0.8. **Please edit them**: correct mistakes, add workflows that were missed, and argue with the recommendations through PRs.

| File | What it is | Read it if you… |
|---|---|---|
| [`01-ai-ml-workflow-map.md`](01-ai-ml-workflow-map.md) | **Reference.** Every workflow that calls an LLM, Jev, embeddings or a Ruby ML model (W1–W23): key files and functions, a diagram, entry and exit, settings and env vars, fan-outs, sync vs async, plus a list of quirks. | are changing anything AI-, rules- or sync-related |
| [`02-ai-architecture-review.md`](02-ai-architecture-review.md) | **Proposal.** Architecture and workflow review from two angles, Rails + Sidekiq and agent-written contributions: challenges, opportunities, simplifications (S1–S10, P1–P5), suggested sequencing. | maintain the codebase or review PRs |
| [`03-ai-user-perspective-review.md`](03-ai-user-perspective-review.md) | **Proposal.** The same workflows from the user's side. It covers three personas, settings scope, understandability, bug reporting, migration (Maybe v0.6.0 upgraders first, then YNAB, Actual, Firefly III, Securo, ChatGPT Finances), personal-finance book concepts, and recommendations U1–U24. | work on UX, onboarding, settings or docs |

## Status

- **Verified against** `main` @ `56105a3b5` (2026-10-22), which includes [#4310](https://github.com/we-promise/sure/issues/4310). The next commit on `main` (`e718e6ebb`, [#4372](https://github.com/we-promise/sure/issues/4372), SMTP docs) touches no AI code.
- `file:line` references were exact at that commit and will drift. Please update them when you touch the code they point to.
- Statements marked *unverified* or listed under *Caveats* have not been checked at runtime.
- Recommendations are proposals, not decisions. Agreed items should become issues that link back here, using their IDs (S1, U22, …).

## Conventions for editing

- Keep the IDs stable (W*, S*, P*, O-*, U*). Other documents and issues refer to them.
- When you fix a fact in one file, search the other two for the same claim. They were checked for consistency when this folder was added.
- **Traceability:** link PRs and issues as `[#1234](https://github.com/we-promise/sure/issues/1234)`. GitHub only auto-links bare `#1234` in issues and PRs, not in repository files, and `/issues/` redirects to PRs as well. Put a section's related PRs in a `> **Related PRs:**` line under its heading, and mark unmerged ones *(open, vX.Y.Z)*. When a tagged open PR merges, drop its *open* marker and update the section text.
- Mermaid diagrams should parse on GitHub. Avoid `;`, `#` and unquoted parentheses in node labels.

## PR traceability index

Every PR or issue referenced in the three documents, grouped by milestone. "Referenced in" gives the document (01, 02, 03) and the section ID. State was taken on 2026-10-23.

### v0.7.6: [milestone 22](https://github.com/we-promise/sure/milestone/22), due 2026-10-31

| # | Title | State | Referenced in |
|---|---|---|---|
| [#4431](https://github.com/we-promise/sure/issues/4431) | fix/Give the bill form a searchable, grouped category picker | merged | 01: W20 |
| [#4430](https://github.com/we-promise/sure/issues/4430) | Show detected bill name in the bill rules section | merged | 01: W19 |
| [#4421](https://github.com/we-promise/sure/issues/4421) | fix(mobile): load full chat history across all pages | merged | 01: W13 |
| [#4401](https://github.com/we-promise/sure/issues/4401) | Redact the Jev endpoint in the self-hosting settings panel | merged | 01: B4, W8 |
| [#4349](https://github.com/we-promise/sure/issues/4349) | Batch load recent paid occurrences during price change detection to prevent N+1 | open | 01: W19 |
| [#4328](https://github.com/we-promise/sure/issues/4328) | Fix Twelve Data per-minute throttle never engaging on Redis | merged | 03: §10, §7.0 |
| [#4310](https://github.com/we-promise/sure/issues/4310) | Add a tunable, self-testing Bayes classifier | merged | 01: D4, W4, W5, W6, W7, W8, header; 02: A4, B4, B5, §0; 03: §5, §7.0 |
| [#4305](https://github.com/we-promise/sure/issues/4305) | Fall back to initials for failed logos and show Brandfetch usage | open | 01: W3; 03: §5 |
| [#4303](https://github.com/we-promise/sure/issues/4303) | Move transfer matching controls beside transaction amounts | merged | 01: W2; 03: §5 |
| [#4299](https://github.com/we-promise/sure/issues/4299) | Keep rejected statements in the vault inbox | merged | 01: W11 |
| [#4295](https://github.com/we-promise/sure/issues/4295) | Update demo assistant banner to credit Vercel AI Gateway | open | 01: W13 |
| [#4291](https://github.com/we-promise/sure/issues/4291) | feat(ai): support Gemini 4 Argon reasoning model | merged | 01: B2; 02: A1 |
| [#4286](https://github.com/we-promise/sure/issues/4286) | Eager-load recurrence rules during occurrence generation to prevent N+1 | merged | 01: W19 |
| [#4263](https://github.com/we-promise/sure/issues/4263) | fix(devcontainer): use the pgvector Postgres image so document import works | merged | 01: W11, W12 |
| [#4262](https://github.com/we-promise/sure/issues/4262) | fix(development): run background jobs through Sidekiq | merged | 01: A2; 02: A8 |
| [#4261](https://github.com/we-promise/sure/issues/4261) | bugfix : honor json_mode in the PDF document extraction path | merged | 01: B2, W11; 02: A2 |
| [#4251](https://github.com/we-promise/sure/issues/4251) | Make the Record payment button submit the manual payment form | merged | 01: W20 |
| [#4249](https://github.com/we-promise/sure/issues/4249) | fix(settings): let LLM_PROVIDER override a stored provider choice | merged | 01: B1; 02: A1, A6 |
| [#4246](https://github.com/we-promise/sure/issues/4246) | Support "not equal to" and "is not empty" for tag rule conditions | merged | 01: W4 |
| [#4244](https://github.com/we-promise/sure/issues/4244) | fix(ai): route chat to the provider selected by LLM_PROVIDER first | merged | 01: B1, W13; 02: A1 |
| [#4243](https://github.com/we-promise/sure/issues/4243) | docs(ai): document the native Anthropic provider | merged | 01: B3 |
| [#4239](https://github.com/we-promise/sure/issues/4239) | feat(insights): deterministic insight text, plus "Dig in with AI" | merged | 01: W17, W18; 02: B4 |
| [#4237](https://github.com/we-promise/sure/issues/4237) | fix(jobs): run AI jobs in their own Sidekiq capsule so they can't starve syncs | merged | 01: A2; 02: A8, B4; 03: §3, §7.0 |
| [#4222](https://github.com/we-promise/sure/issues/4222) | Fix duplicate bill suggestions after renaming a bill | merged | 01: W19 |
| [#4211](https://github.com/we-promise/sure/issues/4211) | Skip email notifications for inactive rules | merged | 01: W4; 03: §7.0 |
| [#4208](https://github.com/we-promise/sure/issues/4208) | Block password changes when only SSO login is allowed | merged | 03: §4 |
| [#4203](https://github.com/we-promise/sure/issues/4203) | Check family access for export, import and document blobs | merged | 01: W12 |
| [#4193](https://github.com/we-promise/sure/issues/4193) | Harden OAuth client registration: reserve "Sure" client names, require https redirect URIs | merged | 01: W15 |
| [#4192](https://github.com/we-promise/sure/issues/4192) | Respect account share permissions in bulk edit and categorize | merged | 01: W8; 02: A11; 03: §4 |
| [#4178](https://github.com/we-promise/sure/issues/4178) | Send tool_choice auto to Claude models that reject a forced tool | merged | 01: B3; 02: A2 |
| [#4176](https://github.com/we-promise/sure/issues/4176) | Record an email action's baseline when it is created | open | 01: W4 |
| [#4175](https://github.com/we-promise/sure/issues/4175) | Validate rule action and resource types against known types | merged | 01: W4 |
| [#4163](https://github.com/we-promise/sure/issues/4163) | Fix MCP rule previews after matching scope rename | merged | 01: W15 |
| [#4158](https://github.com/we-promise/sure/issues/4158) | fix(transfers): reset the kept leg's kind when a transfer leg is deleted | merged | 01: W2 |
| [#4157](https://github.com/we-promise/sure/issues/4157) | feat(mcp): add unmatch_transfer tool | merged | 01: W15 |
| [#4147](https://github.com/we-promise/sure/issues/4147) | Add an "mcp_only" assistant type: no in-app chat, MCP stays available | merged | 01: W14, W15; 03: §3 |
| [#4136](https://github.com/we-promise/sure/issues/4136) | fix(bills): preload recurrence rules and accounts when claiming recurring patterns | merged | 01: W19 |
| [#4133](https://github.com/we-promise/sure/issues/4133) | fix(ai): replay each in-flight tool round as its own message pair | merged | 01: B2, W13 |
| [#4109](https://github.com/we-promise/sure/issues/4109) | Reject null bytes in rule fields | merged | 01: W4 |
| [#4106](https://github.com/we-promise/sure/issues/4106) | Date snoozed bills by their snoozed date in month totals and the plan | merged | 01: W19 |
| [#4089](https://github.com/we-promise/sure/issues/4089) | Add starts with, ends with and regex rule operators | merged | 01: W4 |
| [#4083](https://github.com/we-promise/sure/issues/4083) | Add BalanceSheet::NetWorthVelocity for net worth pace | merged | 01: W17; 03: §8 |
| [#4063](https://github.com/we-promise/sure/issues/4063) | feat(mcp): add delete_category and let update_category move categories | open | 01: W15 |
| [#4061](https://github.com/we-promise/sure/issues/4061) | fix(insights): keep private and unshared accounts out of the shared feed | merged | 01: W17 |
| [#4054](https://github.com/we-promise/sure/issues/4054) | fix(statements): read period and balances from statement PDF text | merged | 01: W11 |
| [#4024](https://github.com/we-promise/sure/issues/4024) | fix(recurring): prevent N+1 in GenerateRecurringOccurrencesJob | merged | 01: W19 |
| [#4021](https://github.com/we-promise/sure/issues/4021) | Show What's new in a DS::Dialog once no drawer or modal is open | merged | 03: §10, §7.0 |
| [#4019](https://github.com/we-promise/sure/issues/4019) | feat(ai-health): let admins set the health check timeout under Self-Hosting | merged | 01: W22; 02: A6 |
| [#4013](https://github.com/we-promise/sure/issues/4013) | feat(rules): run rules in a fixed order with "stop processing" | merged | 01: W4; 02: A4, B4; 03: §5, §7.0 |
| [#4004](https://github.com/we-promise/sure/issues/4004) | Prevent guests from mutating family configuration | merged | 02: A11; 03: §4 |
| [#4002](https://github.com/we-promise/sure/issues/4002) | feat(reports): spending vs normal section (preview) | open | 01: W17; 03: §6 |
| [#4001](https://github.com/we-promise/sure/issues/4001) | Skip account sync for descriptive transaction edits | merged | 01: W1 |
| [#3990](https://github.com/we-promise/sure/issues/3990) | feat(mcp): rule tools with a mandatory preview | merged | 01: W15, W16; 02: B3; 03: §10, §3, §7.1 |
| [#3989](https://github.com/we-promise/sure/issues/3989) | fix(sync): keep a locked date and amount when a provider sync re-imports a transaction | merged | 01: W1 |
| [#3979](https://github.com/we-promise/sure/issues/3979) | feat(ai): support Gemini 3 models and preserve tool call thought signatures | merged | 01: B2; 02: A1 |
| [#3974](https://github.com/we-promise/sure/issues/3974) | Support multi-currency goal funding | merged | 03: §8 |
| [#3961](https://github.com/we-promise/sure/issues/3961) | fix: remember exact release highlight acknowledgements | merged | 03: §7.0 |
| [#3952](https://github.com/we-promise/sure/issues/3952) | feat(reports): family setting to stop counting investing as spending | merged | 03: §4, §8 |

### v0.7.7: [milestone 23](https://github.com/we-promise/sure/milestone/23), due 2026-11-30

| # | Title | State | Referenced in |
|---|---|---|---|
| [#4432](https://github.com/we-promise/sure/issues/4432) | Allow crypto accounts to fund goals | open | 03: §8 |
| [#4343](https://github.com/we-promise/sure/issues/4343) | Fix/loan payment principal split | open | 03: §8 |
| [#3858](https://github.com/we-promise/sure/issues/3858) | Move Bills from the nav into the Plan hub | open | 01: W19; 03: §10, §5, §8 |
| [#3780](https://github.com/we-promise/sure/issues/3780) | Stop SimpleFIN backfill on empty windows, not on payload growth | open | 01: W1 |
| [#3709](https://github.com/we-promise/sure/issues/3709) | Add per-person ownership percentage to accounts | open | 02: A11; 03: §4 |
| [#3694](https://github.com/we-promise/sure/issues/3694) | Suggest models from any OpenAI-compatible `/models` endpoint | open | 01: B2; 02: A1; 03: §10, §3 |
| [#3677](https://github.com/we-promise/sure/issues/3677) | Set up and run development services with mise | open | 02: B8 |
| [#3605](https://github.com/we-promise/sure/issues/3605) | feat(ai): configurable reasoning effort for OpenAI-compatible providers | open | 01: B2; 02: A2, A6; 03: §3 |
| [#3498](https://github.com/we-promise/sure/issues/3498) | Add Physical Cash account type | open | 03: §8 |
| [#3442](https://github.com/we-promise/sure/issues/3442) | Weekly cleanup proactive insights chat for family admins (#3441) | open | 01: W17; 03: §10, §6 |
| [#3428](https://github.com/we-promise/sure/issues/3428) | Track purchase refunds as reductions in spending | open | 03: §8 |
| [#3224](https://github.com/we-promise/sure/issues/3224) | feat(transfers): Allow categorizing transfers on creation and for all… | open | 01: W2 |
| [#3054](https://github.com/we-promise/sure/issues/3054) | Feature/emi installment plans | closed | 03: §8 |
| [#3025](https://github.com/we-promise/sure/issues/3025) | feat(mcp): add practical financial CRUD tools | open | 01: W15, W16; 02: B3; 03: §3 |
| [#1559](https://github.com/we-promise/sure/issues/1559) | chore: track Sure build bootstrap skill | open | 02: B8 |

### Earlier, unscheduled, or issues

| # | Title | State | Referenced in |
|---|---|---|---|
| [#4435](https://github.com/we-promise/sure/issues/4435) | Fix duplicate migration version for classifier rules | merged | 01: W5, W6, header |
| [#4245](https://github.com/we-promise/sure/issues/4245) | Separate LLM settings for chat and background jobs | issue, open | 01: B1; 02: §0, §2.2; 03: §3, §9 |
| [#3505](https://github.com/we-promise/sure/issues/3505) | feat: add "What's new" release highlight popup | merged | 03: §10, §7.0 |
| [#2113](https://github.com/we-promise/sure/issues/2113) | feat(ai): route LLM feature flows (batch ops + PDF) through Setting.llm_provider | issue, closed | 02: B1, §1 |
| [#1985](https://github.com/we-promise/sure/issues/1985) | feat(ai): Anthropic native PDF processing (3/5) | merged | 02: B3 |
| [#1984](https://github.com/we-promise/sure/issues/1984) | feat(ai): Anthropic batch ops + LLM cost ledger (2/5) | merged | 02: B3, B5 |
| [#552](https://github.com/we-promise/sure/issues/552) | Fix disabled rules executing during automatic sync | merged | 03: §11, §7.0 |
