# Proposal v0.8: AI / ML workflows

Working documents for discussing how Sure's AI and ML features should evolve towards v0.8. **Please edit them**: correct mistakes, add workflows that were missed, and argue with the recommendations through PRs.

| File | What it is | Read it if you… |
|---|---|---|
| [`00-ai-ml-block-diagram.md`](00-ai-ml-block-diagram.md) | **Orientation.** One flowchart of the main blocks (entry points, Sidekiq capsules, assistant tools, provider layer, datastores, external services), an ER diagram of the AI/ML models, a legend, and how a request flows. Inferred parts are flagged. | are new to the AI code and want the map before the detail |
| [`01-ai-ml-workflow-map.md`](01-ai-ml-workflow-map.md) | **Reference.** Every workflow that calls an LLM, Jev, embeddings or a Ruby ML model (W1–W23): key files and functions, a diagram, entry and exit, settings and env vars, fan-outs, sync vs async, plus a list of quirks. W15 also documents the MCP server interface. **D5** is the interface register (I1–I27): each interface's contract on `main`, its consumers, whether it is a boundary, where declared and actual contracts have drifted, and (D5.7) which tests hold each interface to its contract. | are changing anything AI-, rules- or sync-related |
| [`02-ai-architecture-review.md`](02-ai-architecture-review.md) | **Proposal.** Architecture and workflow review from two angles, Rails + Sidekiq and agent-written contributions: challenges, opportunities, simplifications (S1–S10, P1–P5), suggested sequencing. | maintain the codebase or review PRs |
| [`03-ai-user-perspective-review.md`](03-ai-user-perspective-review.md) | **Proposal.** The same workflows from the user's side. It covers three personas, settings scope, understandability, bug reporting, migration (Maybe v0.6.0 upgraders first, then YNAB, Actual, Firefly III, Securo, ChatGPT Finances), personal-finance book concepts, and recommendations U1–U24. | work on UX, onboarding, settings or docs |
| [`04-rubyllm-thought-experiment.md`](04-rubyllm-thought-experiment.md) | **Thought experiment.** What if every model call went through [RubyLLM](https://github.com/crmne/ruby_llm)? Code that would go, past PRs that would not have been needed, fit with S1 and S2, the three setups and the transitions between them (T1–T6), regressions, and open questions (Q1–Q18). Not a proposal. | are weighing a client library against the S1/S2 refactor |
| [`05-ai-breaking-change-option.md`](05-ai-breaking-change-option.md) | **Option.** What the refactor would look like if breaking changes were allowed (BC1–BC11): suggestions plus a resolver, classifiers out of Rules, one AI gateway, config, MCP and consent changes. For each change, the D5 interfaces it breaks, merges or removes, how to split it into reviewable PRs, and who notices it (03 personas and U-numbers). Not a decision. | decide the scope of the AI/ML refactor |
| [`06-ai-file-split-review.md`](06-ai-file-split-review.md) | **Review.** Files to split: merge hotspots by six-month churn and overlap across all 330 open PRs, MVC-boundary crossings, and files spanning several resources (F-H, F-M, F-R). A table says whether each split belongs before the refactor, with it, or at any time. | plan the refactor's first PRs, or keep hitting merge conflicts |

## Status

- **Interface register and breaking-change option** (01 D5, 05, and 00) were checked against `main` @ `2250ba801` (2026-10-23). The 10 commits in between change no AI/ML path described in 01 (one touches the email-action baseline in the assistant's rule tools).
- **Verified against** `main` @ `56105a3b5` (2026-10-22), which includes [#4310](https://github.com/we-promise/sure/issues/4310). The next commit on `main` (`e718e6ebb`, [#4372](https://github.com/we-promise/sure/issues/4372), SMTP docs) touches no AI code.
- `file:line` references were exact at that commit and will drift. Please update them when you touch the code they point to.
- Statements marked *unverified* or listed under *Caveats* have not been checked at runtime.
- Recommendations are proposals, not decisions. Agreed items should become issues that link back here, using their IDs (S1, U22, …).

## Consistency check (2026-10-24)

Every claim that appeared in more than one document, or that two documents stated differently, was checked against `main` @ `e5b854536`. Where the documents disagreed, the code decided.

| Claim | Was | Code says | Fixed in |
|---|---|---|---|
| Registered assistant tools | "48 registered" (01 D5.7) vs "30, 44 with preview" (00, 01, 02, 03) | 30 default + 14 preview = 44. The 4 tag/category write tools are removed for guests, not extra tools. 16 of the 30 write data, 21 of the 44. | 01 W13, D5.7; 02 A13 |
| AI env vars | "about 50" (02, 03), "about 25 tuning" (05) | 54 AI variables are read by the app; about 30 are tuning values once secrets, endpoints, identities and process sizing are removed | 05 BC5; 01 D1 (adds `AI_DEBUG_MODE`, `LANGFUSE_REGION`) |
| Precedence code to replace | "about 40 hand-rolled precedence methods" (02 S6, 05) | 68 methods in models, controllers and `lib` read an AI env var themselves, plus 41 `ENV` reads in the AI settings views | 02 S6; 05 BC5, §4 |
| AI job failure handling | "5 AI jobs with copied rescue/callback code" (02 S5) vs drift 5 (01 D5.6) | 2 jobs copy the `RuleRun` block, `ProcessPdfJob` has its own, 2 declare nothing | 02 S5 |
| Open PRs | "≥200" (02, 03) vs 330 (06) | 329 open on 2026-10-24 | 02 §1, B6; 03 §6 |
| Hot files | `config/sidekiq.yml` and `TransactionResource` listed as hotspots (02 B9) | `sidekiq.yml`: 1 commit in six months, no open PRs. The real hotspots are the files in 06 §1. | 02 B9 |
| Registries and collisions | "registries rarely conflict" (02 O-B7) vs F-H4 (06) | Each registry is one hand-written array; `assistant.rb` is changed by 14 open PRs | 02 O-B7 |
| Async rule-action result | `{async: true, jobs_count:}` (01 W8, 05 BC2) vs D5 I10 | `{async: true, modified_count:, jobs_count:}` | 01 W8, D5.7; 05 BC2 |
| AI cache reset button | "debug or rules page" (01 W21, 03 §5) | Rules page only (`rules/index.html.erb`) | 01 W21; 03 §5 |
| Classifier-rule migration | "on if the family had an active AI rule" (03 §7.0) vs "of the matching type" (01 W4, D4) | Matching type: AI merchant rule → matcher, AI categorization rule → classifier | 03 §7.0 |
| Advanced settings group | 11 items listed (03 §7.0) | 13: Imports and Exports were missing (29 entries in all, Maybe had 14) | 03 §7.0 |
| Line references | `rule.rb:233`, `chat.rb:59`, `sidekiq.rb:66` (01) vs `chat.rb:60` (04) | `rule.rb:253` (`apply`), `chat.rb:60` (`default_model`), `sidekiq.rb:68` (`AutoSyncScheduler.sync!`) | 01 B1, W4, A2 |
| Rails version | 8.1.3 (04) | 8.1.3.1, json 2.21.2 | 04 §3 |
| Reference commit | `56105a3b5` (01–03) vs `2250ba801` (04–06) | The commits since `56105a3b5` change no AI/ML code; every checked claim holds at `e5b854536` | 01, 02, 03 headers |

Checked and consistent: the tool split above, the 13 rule executors, the 8 insight generators, the 6 `#2113` comments, the duplicated helpers (5 / 4 / 4), the 16 guides and 7 Cursor rules, the 31 classifier settings, the six AI prompt keys, the model and timeout defaults (`gpt-4.1`, 60 s; `claude-sonnet-4-6`, 600 s, 4,096 tokens; context window 2,048; 8 tool rounds; chat timeout 90 s, minimum 30 s), the 0.7 confidence-threshold schema default, the AI compose values, the job queues and cron times, the Debug log being super-admin only, and Maybe v0.6.0's 4 read-only tools.

Found in the code itself and recorded in 01 D4: the AI compose file's comment still assumes a default of 5 tool rounds (#13), alongside the existing confidence-threshold comment (#11).

Contributors: the brief gave 446, and the GitHub contributors API lists 419 accounts (424 with anonymous). 03 now says **about 450**.

## Conventions for editing

- Keep the IDs stable (W*, S*, P*, O-*, U*, I*, BC*, F-*). Other documents and issues refer to them.
- When you fix a fact in one file, search the other documents for the same claim. 01–06 were checked against each other and against the code on 2026-10-24 (see *Consistency check* below).
- **Traceability:** link PRs and issues as `[#1234](https://github.com/we-promise/sure/issues/1234)`. GitHub only auto-links bare `#1234` in issues and PRs, not in repository files, and `/issues/` redirects to PRs as well. Put a section's related PRs in a `> **Related PRs:**` line under its heading, and mark unmerged ones *(open, vX.Y.Z)*. When a tagged open PR merges, drop its *open* marker and update the section text.
- Mermaid diagrams should parse on GitHub. Avoid `;`, `#` and unquoted parentheses in node labels.

## PR traceability index

Every PR or issue referenced in the documents, grouped by milestone. "Referenced in" gives the document (01–06) and the section ID. State was taken on 2026-10-23, and on 2026-10-24 for the 05 and 01 D5 references.

### v0.7.6: [milestone 22](https://github.com/we-promise/sure/milestone/22), due 2026-10-31

| # | Title | State | Referenced in |
|---|---|---|---|
| [#4431](https://github.com/we-promise/sure/issues/4431) | fix/Give the bill form a searchable, grouped category picker | merged | 01: W20; 05: BC6 |
| [#4430](https://github.com/we-promise/sure/issues/4430) | Show detected bill name in the bill rules section | merged | 01: W19 |
| [#4421](https://github.com/we-promise/sure/issues/4421) | fix(mobile): load full chat history across all pages | merged | 01: W13; 05: BC4 |
| [#4401](https://github.com/we-promise/sure/issues/4401) | Redact the Jev endpoint in the self-hosting settings panel | merged | 01: B4, W8 |
| [#4349](https://github.com/we-promise/sure/issues/4349) | Batch load recent paid occurrences during price change detection to prevent N+1 | open | 01: W19 |
| [#4328](https://github.com/we-promise/sure/issues/4328) | Fix Twelve Data per-minute throttle never engaging on Redis | merged | 03: §10, §7.0 |
| [#4310](https://github.com/we-promise/sure/issues/4310) | Add a tunable, self-testing Bayes classifier | merged | 01: D4, W4, W5, W6, W7, W8, header; 02: A4, A8, B4, B5, §0; 03: §5, §7.0; 05: header, BC1, BC2, §8 |
| [#4305](https://github.com/we-promise/sure/issues/4305) | Fall back to initials for failed logos and show Brandfetch usage | open | 01: W3; 03: §5 |
| [#4303](https://github.com/we-promise/sure/issues/4303) | Move transfer matching controls beside transaction amounts | merged | 01: W2; 03: §5 |
| [#4299](https://github.com/we-promise/sure/issues/4299) | Keep rejected statements in the vault inbox | merged | 01: W11 |
| [#4295](https://github.com/we-promise/sure/issues/4295) | Update demo assistant banner to credit Vercel AI Gateway | open | 01: W13 |
| [#4291](https://github.com/we-promise/sure/issues/4291) | feat(ai): support Gemini 4 Argon reasoning model | merged | 01: B2; 02: A1; 04: §4 |
| [#4286](https://github.com/we-promise/sure/issues/4286) | Eager-load recurrence rules during occurrence generation to prevent N+1 | merged | 01: W19 |
| [#4283](https://github.com/we-promise/sure/issues/4283) | Constrain dynamic MCP OAuth scope to MCP-only token | open | 01: W15, D5; 02: A13; 03: §3, §10; 05: header, BC8; 06: header, §1, §4, §5 |
| [#4263](https://github.com/we-promise/sure/issues/4263) | fix(devcontainer): use the pgvector Postgres image so document import works | merged | 01: W11, W12, D5 |
| [#4262](https://github.com/we-promise/sure/issues/4262) | fix(development): run background jobs through Sidekiq | merged | 01: A2; 02: A8 |
| [#4261](https://github.com/we-promise/sure/issues/4261) | bugfix : honor json_mode in the PDF document extraction path | merged | 01: B2, W11; 02: A2; 04: §4 |
| [#4251](https://github.com/we-promise/sure/issues/4251) | Make the Record payment button submit the manual payment form | merged | 01: W20; 05: BC6 |
| [#4249](https://github.com/we-promise/sure/issues/4249) | fix(settings): let LLM_PROVIDER override a stored provider choice | merged | 01: B1; 02: A1, A6; 04: §4; 05: BC3, BC5 |
| [#4246](https://github.com/we-promise/sure/issues/4246) | Support "not equal to" and "is not empty" for tag rule conditions | merged | 01: W4 |
| [#4244](https://github.com/we-promise/sure/issues/4244) | fix(ai): route chat to the provider selected by LLM_PROVIDER first | merged | 01: B1, W13; 02: A1; 04: §4; 05: BC3 |
| [#4243](https://github.com/we-promise/sure/issues/4243) | docs(ai): document the native Anthropic provider | merged | 01: B3 |
| [#4239](https://github.com/we-promise/sure/issues/4239) | feat(insights): deterministic insight text, plus "Dig in with AI" | merged | 01: W17, W18; 02: A8, B4 |
| [#4237](https://github.com/we-promise/sure/issues/4237) | fix(jobs): run AI jobs in their own Sidekiq capsule so they can't starve syncs | merged | 01: A2; 02: A8, B4; 03: §3, §7.0; 04: §4; 05: header, BC7 |
| [#4222](https://github.com/we-promise/sure/issues/4222) | Fix duplicate bill suggestions after renaming a bill | merged | 01: W19 |
| [#4211](https://github.com/we-promise/sure/issues/4211) | Skip email notifications for inactive rules | merged | 01: W4; 03: §7.0 |
| [#4208](https://github.com/we-promise/sure/issues/4208) | Block password changes when only SSO login is allowed | merged | 03: §4 |
| [#4203](https://github.com/we-promise/sure/issues/4203) | Check family access for export, import and document blobs | merged | 01: W12 |
| [#4193](https://github.com/we-promise/sure/issues/4193) | Harden OAuth client registration: reserve "Sure" client names, require https redirect URIs | merged | 01: W15 |
| [#4192](https://github.com/we-promise/sure/issues/4192) | Respect account share permissions in bulk edit and categorize | merged | 01: W8; 02: A11; 03: §4 |
| [#4178](https://github.com/we-promise/sure/issues/4178) | Send tool_choice auto to Claude models that reject a forced tool | merged | 01: B3; 02: A2; 04: §2, §4 |
| [#4176](https://github.com/we-promise/sure/issues/4176) | Record an email action's baseline when it is created | open | 01: W4 |
| [#4175](https://github.com/we-promise/sure/issues/4175) | Validate rule action and resource types against known types | merged | 01: W4 |
| [#4163](https://github.com/we-promise/sure/issues/4163) | Fix MCP rule previews after matching scope rename | merged | 01: W15 |
| [#4158](https://github.com/we-promise/sure/issues/4158) | fix(transfers): reset the kept leg's kind when a transfer leg is deleted | merged | 01: W2 |
| [#4157](https://github.com/we-promise/sure/issues/4157) | feat(mcp): add unmatch_transfer tool | merged | 01: W15; 06: header, §1 |
| [#4147](https://github.com/we-promise/sure/issues/4147) | Add an "mcp_only" assistant type: no in-app chat, MCP stays available | merged | 01: W14, W15; 02: A13; 03: §3; 05: header, BC8; 06: header, §1 |
| [#4136](https://github.com/we-promise/sure/issues/4136) | fix(bills): preload recurrence rules and accounts when claiming recurring patterns | merged | 01: W19 |
| [#4133](https://github.com/we-promise/sure/issues/4133) | fix(ai): replay each in-flight tool round as its own message pair | merged | 01: B2, W13; 04: §4; 05: BC4 |
| [#4109](https://github.com/we-promise/sure/issues/4109) | Reject null bytes in rule fields | merged | 01: W4 |
| [#4106](https://github.com/we-promise/sure/issues/4106) | Date snoozed bills by their snoozed date in month totals and the plan | merged | 01: W19 |
| [#4089](https://github.com/we-promise/sure/issues/4089) | Add starts with, ends with and regex rule operators | merged | 01: W4 |
| [#4083](https://github.com/we-promise/sure/issues/4083) | Add BalanceSheet::NetWorthVelocity for net worth pace | merged | 01: W17; 03: §8 |
| [#4063](https://github.com/we-promise/sure/issues/4063) | feat(mcp): add delete_category and let update_category move categories | open | 01: W15 |
| [#4061](https://github.com/we-promise/sure/issues/4061) | fix(insights): keep private and unshared accounts out of the shared feed | merged | 01: W17; 05: BC10 |
| [#4054](https://github.com/we-promise/sure/issues/4054) | fix(statements): read period and balances from statement PDF text | merged | 01: W11 |
| [#4024](https://github.com/we-promise/sure/issues/4024) | fix(recurring): prevent N+1 in GenerateRecurringOccurrencesJob | merged | 01: W19 |
| [#4021](https://github.com/we-promise/sure/issues/4021) | Show What's new in a DS::Dialog once no drawer or modal is open | merged | 03: §10, §7.0 |
| [#4019](https://github.com/we-promise/sure/issues/4019) | feat(ai-health): let admins set the health check timeout under Self-Hosting | merged | 01: W22; 02: A6; 05: BC5 |
| [#4013](https://github.com/we-promise/sure/issues/4013) | feat(rules): run rules in a fixed order with "stop processing" | merged | 01: W4; 02: A4, B4; 03: §5, §7.0; 05: BC2 |
| [#4004](https://github.com/we-promise/sure/issues/4004) | Prevent guests from mutating family configuration | merged | 02: A11; 03: §4 |
| [#4002](https://github.com/we-promise/sure/issues/4002) | feat(reports): spending vs normal section (preview) | open | 01: W17; 03: §6 |
| [#4001](https://github.com/we-promise/sure/issues/4001) | Skip account sync for descriptive transaction edits | merged | 01: W1 |
| [#3990](https://github.com/we-promise/sure/issues/3990) | feat(mcp): rule tools with a mandatory preview | merged | 01: W15, W16; 02: A13, B3; 03: §10, §3, §7.1; 05: BC8; 06: header, §1 |
| [#3989](https://github.com/we-promise/sure/issues/3989) | fix(sync): keep a locked date and amount when a provider sync re-imports a transaction | merged | 01: W1 |
| [#3979](https://github.com/we-promise/sure/issues/3979) | feat(ai): support Gemini 3 models and preserve tool call thought signatures | merged | 01: B2; 02: A1; 04: §2, §4 |
| [#3974](https://github.com/we-promise/sure/issues/3974) | Support multi-currency goal funding | merged | 03: §8 |
| [#3961](https://github.com/we-promise/sure/issues/3961) | fix: remember exact release highlight acknowledgements | merged | 03: §7.0 |
| [#3952](https://github.com/we-promise/sure/issues/3952) | feat(reports): family setting to stop counting investing as spending | merged | 03: §4, §8 |
| [#3767](https://github.com/we-promise/sure/issues/3767) | fix(chat): gate chat page behind AI consent and surface OpenAI stream errors | merged | 04: §4, §9 |
| [#3602](https://github.com/we-promise/sure/issues/3602) | fix(ai): retry without strict JSON when Auto mode can't parse the response | merged | 04: §1, §4 |

### v0.7.7: [milestone 23](https://github.com/we-promise/sure/milestone/23), due 2026-11-30

| # | Title | State | Referenced in |
|---|---|---|---|
| [#4432](https://github.com/we-promise/sure/issues/4432) | Allow crypto accounts to fund goals | open | 03: §8 |
| [#4343](https://github.com/we-promise/sure/issues/4343) | Fix/loan payment principal split | open | 03: §8 |
| [#3858](https://github.com/we-promise/sure/issues/3858) | Move Bills from the nav into the Plan hub | open | 01: W19; 03: §10, §5, §8 |
| [#3780](https://github.com/we-promise/sure/issues/3780) | Stop SimpleFIN backfill on empty windows, not on payload growth | open | 01: W1 |
| [#3709](https://github.com/we-promise/sure/issues/3709) | Add per-person ownership percentage to accounts | open | 02: A11; 03: §4 |
| [#3694](https://github.com/we-promise/sure/issues/3694) | Suggest models from any OpenAI-compatible `/models` endpoint | open | 01: B2; 02: A1; 03: §10, §3; 04: §2, §4 |
| [#3677](https://github.com/we-promise/sure/issues/3677) | Set up and run development services with mise | open | 02: B8 |
| [#3605](https://github.com/we-promise/sure/issues/3605) | feat(ai): configurable reasoning effort for OpenAI-compatible providers | open | 01: B2; 02: A2, A6; 03: §3; 04: §2, §4 |
| [#3498](https://github.com/we-promise/sure/issues/3498) | Add Physical Cash account type | open | 03: §8 |
| [#3442](https://github.com/we-promise/sure/issues/3442) | Weekly cleanup proactive insights chat for family admins (#3441) | open | 01: W17; 03: §10, §6 |
| [#3428](https://github.com/we-promise/sure/issues/3428) | Track purchase refunds as reductions in spending | open | 03: §8 |
| [#3224](https://github.com/we-promise/sure/issues/3224) | feat(transfers): Allow categorizing transfers on creation and for all… | open | 01: W2 |
| [#3054](https://github.com/we-promise/sure/issues/3054) | Feature/emi installment plans | closed | 03: §8 |
| [#3025](https://github.com/we-promise/sure/issues/3025) | feat(mcp): add practical financial CRUD tools | open | 01: W15, W16, D5; 02: A13, B3; 03: §3; 05: header, BC8 |
| [#1559](https://github.com/we-promise/sure/issues/1559) | chore: track Sure build bootstrap skill | open | 02: B8 |

### Earlier, unscheduled, or issues

| # | Title | State | Referenced in |
|---|---|---|---|
| [#4435](https://github.com/we-promise/sure/issues/4435) | Fix duplicate migration version for classifier rules | merged | 01: W5, W6, header |
| [#4444](https://github.com/we-promise/sure/issues/4444) | Hold back background AI jobs while someone writes a chat message | open | 01: D5; 05: header, BC7 |
| [#4245](https://github.com/we-promise/sure/issues/4245) | Separate LLM settings for chat and background jobs | issue, open | 01: B1; 02: §0, §2.2; 03: §3, §9; 04: §5; 05: header, BC3 |
| [#3771](https://github.com/we-promise/sure/issues/3771) | Support GPT-6 Sol and GPT-6.1 Sol in the native OpenAI provider | merged (v0.7.5) | 04: §4 |
| [#3727](https://github.com/we-promise/sure/issues/3727) | fix(ai): send OpenAI-compatible tool payloads that strict endpoints accept | merged (v0.7.5) | 04: §4 |
| [#3505](https://github.com/we-promise/sure/issues/3505) | feat: add "What's new" release highlight popup | merged | 03: §10, §7.0 |
| [#3373](https://github.com/we-promise/sure/issues/3373) | feat(prompts): Editable Built-In Prompt Overrides Per-Family | merged (v0.7.5) | 04: §4 |
| [#3362](https://github.com/we-promise/sure/issues/3362) | feat(ai): support OPENAI_EXTRA_HEADERS on the OpenAI-compatible provider | merged (v0.7.5) | 04: §4 |
| [#3304](https://github.com/we-promise/sure/issues/3304) | Add configurable OpenAI request timeout | merged (v0.7.5) | 04: §4 |
| [#2937](https://github.com/we-promise/sure/issues/2937) | fix(providers): capture API error response body in PDF processor span output | merged (v0.7.4) | 04: §4 |
| [#2767](https://github.com/we-promise/sure/issues/2767) | Fix chained assistant tool calls | merged (v0.7.4) | 04: §4 |
| [#2755](https://github.com/we-promise/sure/issues/2755) | fix(ai): prevent Anthropic chat crash on no-argument tool calls | merged (v0.7.3) | 04: §4 |
| [#2690](https://github.com/we-promise/sure/issues/2690) | Update LLM token cost estimates and cost-info locales | merged (v0.7.3) | 04: §4 |
| [#2113](https://github.com/we-promise/sure/issues/2113) | feat(ai): route LLM feature flows (batch ops + PDF) through Setting.llm_provider | issue, closed | 02: B1, §1 |
| [#1985](https://github.com/we-promise/sure/issues/1985) | feat(ai): Anthropic native PDF processing (3/5) | merged | 02: B3; 04: §4 |
| [#1984](https://github.com/we-promise/sure/issues/1984) | feat(ai): Anthropic batch ops + LLM cost ledger (2/5) | merged | 02: B3, B5; 04: §4 |
| [#1983](https://github.com/we-promise/sure/issues/1983) | feat(ai): add Anthropic provider with chat parity (1/5) | merged (v0.7.2) | 04: §4 |
| [#1968](https://github.com/we-promise/sure/issues/1968) | feat: add Google Gemini as alternative LLM provider | closed | 04: §4 |
| [#1669](https://github.com/we-promise/sure/issues/1669) | Fix OpenAI Responses API stream error handling | merged (v0.7.1) | 04: §4 |
| [#1144](https://github.com/we-promise/sure/issues/1144) | Guard error.message with rescue in LLM failed-usage recording | merged (v0.6.9) | 04: §4 |
| [#552](https://github.com/we-promise/sure/issues/552) | Fix disabled rules executing during automatic sync | merged | 03: §11, §7.0 |
| [#467](https://github.com/we-promise/sure/issues/467) | Fix api call for cloudflare API | merged (v0.6.6) | 04: §4 |
| [#360](https://github.com/we-promise/sure/issues/360) | Track failed LLM API calls in llm_usages table | merged | 04: §4 |
| [#225](https://github.com/we-promise/sure/issues/225) | Fix "Messages is invalid" error for Ollama/custom LLM providers and add comprehensive AI documentation | merged | 04: §4, §9 |
| [#223](https://github.com/we-promise/sure/issues/223) | Llm cost estimation | merged | 04: §4 |
| [#213](https://github.com/we-promise/sure/issues/213) | Implement support for generic OpenAI api | merged | 04: §4 |
