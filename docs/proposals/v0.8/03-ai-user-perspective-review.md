# Sure: AI / ML workflows from the user's point of view

**Companion to:** [`01-ai-ml-workflow-map.md`](01-ai-ml-workflow-map.md) (how it works) and [`02-ai-architecture-review.md`](02-ai-architecture-review.md) (how it is built)
**Reference:** `we-promise/sure` `origin/main` @ `56105a3b5` (2026-10-22). Facts re-checked against `main` @ `e5b854536` on 2026-10-24.
**Question this review answers:** for the people who *use* Sure, do the AI/ML workflows do what they came for, can they understand them, can they report problems, and do the defaults just work?

This is not a code review. File references appear only where they show what a user actually sees.

---

## 0. Verdict in one page

| Question | Short answer |
|---|---|
| Do defaults work out of the box? | **Mostly, for persona 1 (no LLM). Fragile for persona 2.** With no LLM, nothing AI-related breaks, and the classifier rules sit quietly until there is enough history. With a "simple" LLM (the documented Ollama compose), the defaults (2,048-token context, an 8B model, non-streaming chat, one AI worker thread) produce slow or truncated results that look like bugs. |
| Do workflows match what users want? | **The building blocks are right; the framing is engineering-first.** Users want "categorize my spending", "warn me about bills", "am I on track?". Sure gives them *Rules*, *Merchant matcher*, *Category classifier*, *Auto-categorize with AI*, *Enhance merchants*, *Statement vault*, *AI prompts*, *LLM usage* and *MCP*: nine nouns for roughly three jobs. |
| Simple to understand? | **No for categorization, yes for insights and bills.** Categorization happens in four places (provider data, rules, Bayes, AI) with three lock behaviours, and the Classifier page speaks ROC-AUC, complement NB and Lidstone smoothing. Insights, bills and the paycheck plan are plain-language and concrete. |
| Exposed enough for bug reports, without overwhelming? | **Inverted.** Tuning internals are exposed to every family admin (classifier knobs, prompts, JSON mode), while the things a user needs to *report* a problem (why this category, did AI run last night, what failed) are hidden: provenance is not shown per transaction, and the Debug log is super-admin only. |
| Are user vs family settings scoped right? | **Several mis-scopes.** Instance-wide API keys and model settings live on a page any *family admin* can edit. Language is already personal (a per-user locale overrides the family's), but timezone and date format are *family* settings that any member can change for everyone. AI consent is per *user*, but AI rules run for the whole *family* regardless. |
| Easy for **Maybe v0.6.0 upgraders**? | **Data: seamless (same database). Behaviour: silently different.** Rules now run in order and only when active, two system rules appear, the assistant can now write data under a consent given for a read-only assistant, and market data stops updating (Synth is gone, and the default provider needs a key). There is no upgrade guide and no in-app "what changed" screen. See §7.0. |
| Easy for migrants from YNAB / Actual / Firefly III / Securo / ChatGPT? | **Accounts and rules: yes. Budgeting philosophy: partly. AI trust model: no.** Importers exist for YNAB, Actual, Mint, QIF and CSV, but there is **no Firefly III importer** and no OFX or CAMT support (formats Securo and Firefly users have). Actual users will recognise ordered rules. YNAB users will look for "Ready to Assign". ChatGPT Finances users expect zero setup, read-only AI and viewable memories, while Sure's assistant can change data without asking. |
| Does it echo popular personal-finance books? | **More than most apps:** net worth (assets vs liabilities), savings-rate change, months-of-expenses reserve goals, idle cash, subscription audit, paycheck planning. **Missing the frameworks people actually quote:** bucket or percentage plans (Barefoot, IWT, 50/30/20), "pay yourself first", debt snowball, passive vs earned income, decumulation ("die with zero"). |

**Top recommendations from the user's side:**
0. **Maybe v0.6.0 upgraders first** (§7.0): they are the largest existing audience and they swap images on a live database. Add an upgrade guide, a one-time "what changed" screen, read-only assistant until re-consent, and a keyless market-data default.
1. **A setup tier switch** (*Off / Simple / Custom*) that hides everything above the user's tier and picks defaults that work for that tier.
2. **One user-facing concept, "Auto-categorize"**, with a stage list ("matched similar → learned from your history → asked AI → your rules"), instead of four mechanisms.
3. **"Why this category?" on every transaction, plus a "Report a problem" button** that bundles redacted diagnostics. Make transparency per transaction, not per subsystem.
4. **Fix the scopes:** instance settings to super-admin only, personal settings (timezone, date format, AI consent; language already is) per user, household settings per family.
5. **Plan templates** (Barefoot buckets, IWT Conscious Spending Plan, 50/30/20, YNAB-style zero-based) that map onto existing categories, budgets, goals and the paycheck plan.

---

## 1. The three users

| | **P1. Simple, no LLM** | **P2. Simple, one LLM** | **P3. Custom: multiple LLMs, external agents** |
|---|---|---|---|
| Who | Household, self-hosts via the default compose or uses a hosted instance | Same household, plus "turn on AI": an OpenAI or Anthropic key, or the Ollama compose | Tinkerer or power user. Several models (local plus cloud), Jev, external agent (OpenClaw), MCP clients. **Setup likely done by Claude Code on their behalf.** |
| Wants | See all accounts, know where money goes, budget, not miss bills | All of P1, with less manual categorizing, plus "ask questions about my money" | All of P2, plus control of cost, privacy and quality, and their own agents acting on their data |
| Reads | The UI. Maybe the README. | The UI and the AI hosting doc | Docs, env vars, the code (via the agent) |
| Tolerance for internals | None | Low | High, but **the person is not the one reading**: their agent is |
| Biggest risk | Seeing AI features they can't use | Defaults that "work" but feel broken (slow, truncated, wrong) | Silent mis-routing (wrong model or provider per task), unexplained cost, settings changed by the agent that the human can't see or undo |

---

## 2. What users come to do vs what the workflows are

Users think in **jobs**. Here is how each job maps to Sure's workflows (W-numbers from the workflow map):

| User job ("I want to…") | Workflows involved | Fit | Comment |
|---|---|---|---|
| …get all my accounts in one place | W1 sync, imports, W11 PDF | **Good** | Many bank providers. PDF statements via AI is a strong differentiator for countries without bank APIs. |
| …have my transactions categorized without effort | W5 matcher, W6 Bayes, W8 AI, W9 merchants, W4 rules, provider categories | **Right engine, confusing surface** | Four mechanisms, three settings pages (Rules, Classifier, Self-hosting), two cost models (free vs paid). The user can't predict which one categorized what. |
| …clean up merchant names and logos | W9, W10, W3, provider data | **Fair** | "Enhance merchants" is a button whose effect is invisible until logos appear. Merchants created by AI vs provider vs matcher look the same. |
| …not miss bills, know what's safe to spend | W19 recurring, W20 smart-fill, paycheck plan | **Good** | Concrete and plain-language. Detection runs after every sync. |
| …know if I'm on track | W17 insights, budgets, goals | **Good** | Insights are deterministic, explain themselves, and resurface only when the numbers change. Preview-gated, so most users never see them. |
| …ask questions about my money | W13 chat, W18 dig-in | **Good with cloud models, poor with small local ones** | Tool-calling chat is powerful, but on the default Ollama setup it is slow, non-streaming and often wrong. |
| …let my own AI agent manage my money | W14 external, W15 MCP | **Capable, expert-only** | MCP plus OAuth is right. There is no "what did my agent change?" view for the human. |
| …trust the numbers | provenance, locks, debug | **Weak** | No per-transaction "why". The debug log is admin-only and engineer-worded. |
| …control AI cost and privacy | LLM usage page, consent, provider choice | **Partial** | The usage page exists. Consent is per user but bypassed by family AI rules (see §4). |

**Pattern:** workflows that map 1:1 to a job (bills, insights, imports) are understood. Workflows that are *mechanisms serving* a job (matcher, Bayes, AI categorize, merchant enhance, cache reset, JSON mode) leak their implementation into the UI.

---

## 3. Journeys per persona

### P1: simple setup, no LLM

**What happens today**
1. Install with the default compose, then onboarding (preferences, then "What brings you here?" goals, which includes "Let AI help me understand my finances"), then connect a bank or import.
2. The family gets **two rules it didn't create**: "Merchant matcher" and "Category classifier" (active for new families). They do nothing until there are 20+ categorized transactions and 2+ categories, then they start filling quietly.
3. Rules page: AI actions are hidden when no provider is configured (good). The Classifier rules are listed as ordinary rules with no explanation of what they are.
4. The settings nav still shows **Advanced → AI prompts, Classifier, LLM usage, MCP** to admins, plus a **Self-hosting** page whose first section is "AI assistant".
5. Chat or "AI" entry points prompt for consent, then explain that AI isn't configured.

**Works by default?** Yes. Nothing fails, and Bayes starts helping after a few weeks of manual categorizing. That is a good free baseline.

**Friction**
- **Cold start is silent.** The user categorizes manually for weeks with no hint that the system is learning. A progress cue ("Sure has learned from 12 of 20 transactions needed to start suggesting categories") would turn a hidden mechanism into motivation.
- **AI-only pages are visible with no AI.** Five settings pages that can't do anything for this user add noise.
- **Onboarding asks about AI goals but doesn't act on them.** The selected `goals` are stored on the user, but nothing in the app branches on them. Picking "AI insights" without a provider leads nowhere.
- **The two system rules look like user rules.** People delete them ("I didn't make these"), and later wonder why categorization got worse.

### P2: simple setup, one LLM

> **Related PRs:** [#3694](https://github.com/we-promise/sure/issues/3694) *(open, v0.7.7)* model suggestions from /models, answers "which model?" · [#3605](https://github.com/we-promise/sure/issues/3605) *(open, v0.7.7)* reasoning effort for slow reasoning models · [#4237](https://github.com/we-promise/sure/issues/4237) AI capsule

**Typical paths:** (a) paste an OpenAI or Anthropic key in Self-hosting, or (b) use `compose.example.ai.yml` (Ollama with `llama3.1:8b`, pgvector, mxbai embeddings).

**What happens today**
1. Chat works once the user also enables AI consent for themselves.
2. **Auto-categorization does not turn on by itself.** The user has to create a rule with "Auto-categorize transactions with AI". The onboarding goal "Let AI help me" doesn't do it, and nothing suggests it.
3. The **Classifier rules stay inactive** for existing families that had no AI rule (by migration design), and **active** for new families. Two households on the same version behave differently.
4. With path (b): the default `LLM_CONTEXT_WINDOW=2048` means batches are cut small and chat history is aggressively trimmed. The system prompt plus 30 tool definitions (44 with preview features) is already near the limit. The chat is non-streaming, so nothing appears for minutes. The compose file documents this ("Local models are not streamed, so the chat shows nothing until the whole reply is generated") and compensates by cutting the tool-call rounds from 8 to 2 (`ASSISTANT_MAX_TOOL_CALL_ITERATIONS=2`) and raising the chat timeout to 20 minutes (`AI_RESPONSE_TIMEOUT=1200`). It does not set `LLM_CONTEXT_WINDOW`.
5. One AI worker thread. Chat waits behind background AI jobs. On the author's own instance this was measured at **56–104 s** of chat waiting while a categorization batch ran, versus 0 s with an experimental hold (not upstream).

**Works by default?** **Cloud key: yes.** **Local compose: technically yes, but experienced as "broken"**: slow, truncated, sometimes wrong tool calls, and no visible progress.

**Friction**
- **Turning on AI is three separate acts** (provider key, per-user consent, an AI rule). Users expect one.
- **"Which model should I pick?"** The model field is free text. The context-window and timeout fields sit next to it without guidance on what to choose for an 8B local model vs a cloud model.
- **Cost is visible after the fact** (LLM usage page) but not at decision time, except as a small estimate inside the rule action label.
- **AI mistakes are sticky.** AI-set categories are locked, so later rules and Bayes never correct them. The user has to find the "reset AI cache" action, or edit each transaction.
- **Expectation mismatch:** the user changes the model and every past AI category becomes editable by AI again (the cache reset), but only if the change was made in the UI and only for OpenAI. Users won't know which happened.

### P3: custom setup (likely configured by Claude Code)

> **Related PRs:** [#4147](https://github.com/we-promise/sure/issues/4147) mcp_only assistant type · [#3025](https://github.com/we-promise/sure/issues/3025) *(open, v0.7.7)* MCP CRUD with idempotency keys · [#3990](https://github.com/we-promise/sure/issues/3990) rule tools with preview · [#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)* MCP-only `mcp` scope

**What happens today**
- Configuration is spread across **env vars** (about 50 AI-related), **instance settings** (Self-hosting), **family columns** (assistant type, categorization provider, threshold, shadow rate, prompts, classifier tuning) and **user flags** (consent, preview features, layout). ENV values override the UI silently.
- Per-task routing (chat on Claude, background on local, Jev for categories) is only partly possible. "One provider for everything except Jev for categories" is what exists today (per-task models are proposed in [#4245](https://github.com/we-promise/sure/issues/4245)).
- The external agent and MCP clients act with the user's permissions. There is no view of "changes made by my agent", and agent-made changes look like user edits.
- Connecting an MCP client is all or nothing: the OAuth grant has to be `read_write` (`mcp` after [#4283](https://github.com/we-promise/sure/issues/4283), which still covers every tool), so "let my agent read, but not change, my data" can't be expressed. Write tools carry no `destructiveHint`, so the client can't warn before a delete ([01 W15](01-ai-ml-workflow-map.md#the-interface-sure-exposes), [02 A13](02-ai-architecture-review.md)).

**Works by default?** It works once configured. The risk is **configuration the human can't see**: an agent sets `CATEGORIZATION_PROVIDER=jev` or `LLM_JSON_MODE=none` in `.env`, and the UI shows a disabled selector, or a value that differs from what runs. When something goes wrong, neither the human nor the next agent session can easily reconstruct the effective configuration.

**Friction**
- **No effective-configuration view** ("what is actually in force, and where did it come from: ENV, Setting or default?") outside the super-admin System Health page.
- **There is no declarative config file** an agent can write and a human can read and diff (`sure-ai.yml`), only env vars plus DB settings.
- **Shadow comparison, the confidence threshold and Jev** are powerful, but their results show only on the Self-hosting page.
- **Two containers, two configurations.** An agent configuring Helm, Podman or bare metal sets env per process, and must know which process reads what. For example, `AI_RESPONSE_TIMEOUT` is read only by the web container and `ASSISTANT_MAX_TOOL_CALL_ITERATIONS` only by the worker ([01 D3](01-ai-ml-workflow-map.md#which-process-reads-which-setting)). Setting a value on the wrong side does nothing, and nothing reports it.
- **More models do not mean more lanes.** Chat, categorization, merchant detection, enhancement and PDF import all share one AI worker thread by default, whichever provider each uses. Routing chat to a fast cloud model doesn't stop it queuing behind a slow local categorization batch. Only `RAILS_AI_MAX_THREADS` changes that, and it is not mentioned on any settings page.

---

## 4. Settings scoping review

> **Related PRs:** [#4004](https://github.com/we-promise/sure/issues/4004) guests can't change family config · [#4192](https://github.com/we-promise/sure/issues/4192) share permissions in bulk categorize · [#3952](https://github.com/we-promise/sure/issues/3952) family setting: investing is not spending · [#3709](https://github.com/we-promise/sure/issues/3709) *(open, v0.7.7)* per-person ownership percentage · [#4208](https://github.com/we-promise/sure/issues/4208) SSO-only password changes

### 4.1 Current state

| Setting | Stored as | Edited on | Who can edit | Affects |
|---|---|---|---|---|
| OpenAI / Anthropic keys, base URLs, models, timeouts, JSON mode, context window, max tokens, items per call | **Instance** (`Setting`) | Self-hosting | **any family admin** (`Current.user.admin?`; super-admin is required only for onboarding settings) | **all families on the instance** |
| `LLM_PROVIDER` (OpenAI vs Anthropic) | Instance | Self-hosting | family admin | all families |
| External assistant URL, token, model | Instance | Self-hosting | family admin | all families |
| Assistant type (builtin / external / MCP-only) | **Family** | Self-hosting (section "AI assistant") | family admin | the family |
| Categorization provider, confidence threshold, shadow rate | **Family** | Self-hosting | family admin | the family |
| AI prompts (6 keys) | Family | Advanced → AI prompts | family admin | the family |
| Classifier tuning (~30 knobs) and classifier rules | Family | Advanced → Classifier, Rules | family admin | the family |
| AI rules | Family | Rules | admin / member | the family's transactions, **all members' accounts in scope** |
| AI consent (`ai_enabled`) | **User** | chat consent prompt | the user | chat and bill AI **only** |
| Language | **User** (`users.locale`), falling back to the browser language, then `families.locale` | Preferences | the user | the user |
| Timezone, date format, country, month start day | **Family** (`families.timezone/date_format/country/month_start_day`) | Preferences | **any member** (not admin-gated) | every member |
| Currencies, budgets | Family | Preferences | admin | every member |
| Preview features, UI layout, AI sidebar | User | Preferences / appearance | the user | the user |
| Auto-sync time | Instance | Self-hosting | family admin | all families |
| Debug log, background jobs, system health | n/a | Advanced | **super-admin** | n/a |

### 4.2 Findings

1. **Instance settings are editable by family admins.** On a single-family self-host this doesn't matter. On any multi-family instance (shared with relatives, or a small hosted community), one family admin can change the model, the provider, or the API key (and so the cost and data destination) for everyone. Instance-wide AI settings should require super-admin, as Debug and System Health already do.
2. **Family settings live on the instance page.** Assistant type and categorization provider are per family but appear on the "Self-hosting" page, so users of a hosted Sure never see them. Move them to a family **AI** page.
3. **Personal preferences are family-wide.** Language already has a per-user override, but timezone and date format are household columns, and any member can change them for everyone from their own Preferences page. Members in different time zones can't each have their own. These are classic **user** settings. Budget period, currency and sharing defaults are correctly **family** settings.
4. **Consent is personal, but data flow is household-wide.** A member who declined AI still has their transactions sent to the provider by a family AI rule. Either make AI rules skip accounts owned by non-consenting members, or make AI a household decision taken by an admin with a clear notice to every member. Pick one and say so in the UI.
5. **Tuning sits at the same level as basics.** The Classifier page exposes 30+ statistical knobs to every family admin. These belong in an "Expert" disclosure. "Find best settings" plus "Apply" is the right user-level control; the knobs are not.
6. **ENV silently wins.** When ENV overrides a setting, the UI shows the stored value or disables the field without explaining. Users editing a field that has no effect is a support ticket waiting to happen. It gets worse when the web and worker containers have different env: the page reflects the **web** container's ENV, while categorization, PDF import and chat replies run in the **worker** ([01 D3](01-ai-ml-workflow-map.md#which-process-reads-which-setting)).

### 4.3 Proposed scoping

| Scope | Who | Contains |
|---|---|---|
| **Instance** (super-admin) | operator | providers, keys, endpoints, models per task, timeouts, worker lanes, vector store, sync schedule, which features are available to families |
| **Household** (family admin) | the household's admin | "Use AI for: chat ☐ categorization ☐ merchants ☐ PDF ☐ bills" (only what the instance offers), categorization source (AI / Jev), classifier on/off, budgets, currencies, month start, sharing |
| **Personal** (each user) | every member | language, timezone, date format, AI consent ("my accounts may be sent to AI"), preview features, layout |
| **Expert** (admin, behind a disclosure) | advanced | classifier tuning, prompts, JSON mode, shadow comparison, MCP and API keys |

---

## 5. Understandability, workflow by workflow

> **Related PRs:** [#4013](https://github.com/we-promise/sure/issues/4013) rule order · [#4310](https://github.com/we-promise/sure/issues/4310) classifier rules · [#4305](https://github.com/we-promise/sure/issues/4305) *(open, v0.7.6)* logo initials fallback · [#4303](https://github.com/we-promise/sure/issues/4303) transfer matching controls · [#3858](https://github.com/we-promise/sure/issues/3858) *(open, v0.7.6)* Bills into Plan hub

| Workflow (user-visible name) | What the user sees | Understood? | Suggestion |
|---|---|---|---|
| Sync | sync button, toast, account status | ✅ | Name the post-sync steps in the toast: "Synced, matched 2 transfers, categorized 14". |
| Transfer matching | pending transfer badges to confirm | ✅ | Good pattern (suggest, then confirm). Reuse it for AI categories (see §6). |
| Rules | ordered list, "stop processing", apply | ✅ for Actual users, ⚠️ for others | Explain order in one line at the top: "Rules run top to bottom. The first rule to set a field wins." |
| **Merchant matcher** rule | a rule with no conditions | ❌ | Show it as a *system step* with an explanation ("Copies a merchant from very similar past transactions"), not as a user rule. Allow disabling it, discourage deleting it. |
| **Category classifier** rule | same | ❌ | "Learns from your past categories. Free and private. Needs about 20 categorized transactions to start." Show learning progress. |
| Auto-categorize with AI (rule action) | label with a cost estimate | ⚠️ | Users expect a switch, not a rule. Offer "Turn on AI categorization", which creates the rule for them, under the classifier step. |
| Auto-detect merchants with AI ($$) | rule action | ⚠️ | "$$" is honest but vague. Show the cost per 100 transactions in the user's currency. |
| Enhance merchants | button on the Merchants page | ❌ | Rename to "Find websites and logos for merchants (uses AI)". Show results. |
| Classifier settings page | knobs, ROC-AUC tables, "Find best settings" | ❌ for P1/P2, ✅ for P3 | Default view: accuracy in plain words ("Got 87% right last month"), one *Improve* button, one *Undo*. The tables go behind Expert. |
| AI prompts | six text areas | ❌ for P1/P2 | Expert only. Fine for P3. |
| LLM usage | tokens and cost per call | ⚠️ | Summarize per feature and per month ("Chat $1.20, Categorization $0.40") before the per-call table. |
| Statement vault / PDF import | upload, then a review screen | ✅ | Good review step. Say "AI read this statement" and show confidence or problems per row. |
| Chat | consent, then chat | ✅ (cloud), ⚠️ (local) | When the model is slow or local, show progress ("checking your accounts…") instead of a silent bubble. |
| Insights | cards with "Dig in with AI" | ✅ | Strong. Un-preview them when stable. They are the most "personal finance book"-like feature. |
| Bills, smart-fill, paycheck plan | dialogs and a calendar | ✅ | The paycheck plan is the closest thing to Barefoot buckets. Promote it. |
| AI cache reset | button on the Rules page | ❌ | Rename to "Let AI re-check its earlier categories". Show what it will unlock. |
| MCP / API keys | token pages | ✅ for P3 | Add an "Activity by this key" view. |

**The core understandability problem is categorization.** There are six possible sources (provider, rule, matcher, Bayes, AI, user), and the user sees only the result. A single mental model fixes most of it:

```mermaid
flowchart LR
    A["New transaction"] --> B["Your rules<br/>(in your order)"]
    B --> C["Similar past transactions<br/>free, private"]
    C --> D["Learned from your history<br/>free, private"]
    D --> E["AI (if turned on)<br/>costs, leaves your server"]
    E --> F["You<br/>always wins"]
```

The app *already* runs roughly this pipeline (as rules ordered by position). It just never shows it to the user as one picture.

---

## 6. Transparency: enough to report a bug, not so much it overwhelms

> **Related PRs:** [#3442](https://github.com/we-promise/sure/issues/3442) *(open, v0.7.7)* weekly cleanup chat surfaces data problems · [#4002](https://github.com/we-promise/sure/issues/4002) spending vs normal

### What a user can see today
- The result (category, merchant). **Not** the source, confidence or time.
- Rule runs (status, counts) on the Rules page.
- LLM usage (per call).
- Debug log and System health: **super-admin only**, in engineer language.

### What a user needs to file a useful bug or feature request
1. *Which* step set the value (rule name, matcher, classifier with confidence, AI with model, provider).
2. *When* it ran, and whether a run failed.
3. The relevant configuration (tier, provider, model, overrides), **redacted**.
4. Version and instance type.

### Proposal: three layers of disclosure

| Layer | Audience | Content |
|---|---|---|
| **1. Inline** | everyone | A small source chip on a transaction's category or merchant: "Rule: Groceries", "Learned (91%)", "AI", "Bank", "You". Click for details. |
| **2. Explain panel** | curious users | "Why this category?": the stages in order, which one answered, confidence, when, and a "This is wrong" button (which feeds Bayes and unlocks). |
| **3. Report a problem** | anyone filing an issue | One button that assembles a redacted bundle (version, tier, provider and model names without keys, the last runs of the relevant workflow and their errors, the explain-panel data with transaction text masked) and copies it, or opens a pre-filled GitHub issue. |

This turns Sure's existing internals (`DataEnrichment` source and metadata, `RuleRun`, `DebugLogEntry`, AI health) into user value **without** exposing the machinery by default. It also cuts maintainer triage time directly. With about 450 contributors and about 340 open PRs, issue quality is a real bottleneck.

The "This is wrong" button closes the loop that users expect from AI ("it learns from my corrections"). Bayes already learns from corrections, but users don't know that.

---

## 7. Migrating users: do the concepts carry over?

### 7.0 Upgrading from Maybe v0.6.0 (the most important group)

> **Related PRs:** [#552](https://github.com/we-promise/sure/issues/552) disabled rules no longer run on sync · [#4013](https://github.com/we-promise/sure/issues/4013) rule order · [#4310](https://github.com/we-promise/sure/issues/4310) classifier rules migration · [#4211](https://github.com/we-promise/sure/issues/4211) inactive rules send no emails · [#4237](https://github.com/we-promise/sure/issues/4237) AI capsule · [#4328](https://github.com/we-promise/sure/issues/4328) Twelve Data throttle · [#3505](https://github.com/we-promise/sure/issues/3505) What's new dialog · [#4021](https://github.com/we-promise/sure/issues/4021) What's new as DS::Dialog · [#3961](https://github.com/we-promise/sure/issues/3961) release acknowledgements

Sure is the community fork of Maybe Finance. Maybe's final release, **v0.6.0 (tag dated 2025-07-24)**, is the point where the projects split. Maybe self-hosters are not *migrating*: they **swap the Docker image** (`ghcr.io/maybe-finance/maybe:latest` → `ghcr.io/we-promise/sure:stable`) on the same database, and Sure's migrations run on start-up. Their data, rules, categories, merchants, chats and settings all carry over. **What changes is behaviour**, often silently, which makes this group both the easiest to bring over and the easiest to surprise.

The comparison below was made against the `v0.6.0` tag in Sure's own git history (Maybe's code) and current `origin/main`.

#### What a Maybe user had, and what changes for them

| Area | Maybe v0.6.0 | Sure today | What the upgrader will notice | Risk |
|---|---|---|---|---|
| **AI provider** | OpenAI only. Key via `OPENAI_ACCESS_TOKEN`. Model fixed to `gpt-4.1`. No custom endpoint. No AI settings UI. | OpenAI, OpenAI-compatible (Ollama…), Anthropic, Jev. Settings UI. Default model is still `gpt-4.1`. | Nothing breaks: the env key and default model still work. ✅ The Self-hosting page now opens with an "AI assistant" section and about 10 AI fields they never needed. | Low |
| **Assistant capabilities** | **4 read-only tools**: accounts, balance sheet, income statement, transactions | **30 tools, 16 of which change data**: create or update rules, transactions, budgets, categories, tags, goals; apply rules; import statements. 44 tools with preview features. | The assistant can now **change their data**. Their `ai_enabled` consent was given in Maybe **for a read-only assistant** and silently carries over. | **High (trust).** See U18 and U24. |
| **When rules run** | On every sync, `family.rules.each(&:apply_later)`: **every rule, including disabled ones, each in its own job, unordered, at the *start* of the sync** (before new transactions arrive). The toggle in Maybe's UI only affected the display; it was a bug, which Sure fixed in [#552](https://github.com/we-promise/sure/issues/552) ("Fix disabled rules executing during automatic sync") | Once per sync, **after** the sync; **only active rules**; in **position order** with "top rule wins" and "stop processing" | Rules now act on the *new* transactions of that sync (better). Rule *order* now matters. **Rules the user had switched off were still running in Maybe, and now really stop.** Categorization that silently depended on a "disabled" rule changes after the upgrade. | **Medium–high** (silent change in categorization) |
| **New rules they didn't create** | none | **"Merchant matcher"** (position 1) and **"Category classifier"** (position 2) inserted at the top. The migration turns each one **on only if the family had an active AI rule of the matching kind** (an AI merchant rule for the matcher, an AI categorization rule for the classifier). | Two unfamiliar rules at the top. For families that used AI rules, Bayes now categorizes *before* the AI, so categories change and AI cost drops. | Medium (confusion), Low (data) |
| **AI categorization results** | locked once set (`lock_attr!`) | still locked | Same. ✅ | n/a |
| **Background jobs** | one Sidekiq pool, `RAILS_MAX_THREADS` (default 3) | a default pool (`RAILS_MAX_THREADS − RAILS_AI_MAX_THREADS` = 2) plus an **AI lane with 1 thread** | With the same env, there are fewer threads for syncs and AI work is serialized. Chat can wait behind categorization jobs. | Medium (performance) |
| **Market data (FX and prices)** | **Synth** (`SYNTH_API_KEY`). Synth no longer exists. | default exchange-rate and securities provider **`twelve_data`, which needs an API key**. Keyless Yahoo Finance is available but **not the default**. | After upgrade, **exchange rates and security prices stop updating** unless they choose a provider. Multi-currency net worth goes stale **silently** (no provider means no fetch, by design). | **High.** It breaks the "defaults just work" principle. See U23. |
| **Settings navigation** | 14 entries | 29 entries, including an *Advanced* group (AI prompts, Classifier, LLM usage, API keys, MCP, Debug, Background jobs, Self-hosting, Imports, Exports, SSO, Users, System health) | It feels like a different, more technical app. | Medium (overwhelm). U1 tiers help most here. |
| **Imports** | CSV (transactions, trades, accounts), Mint | adds YNAB, Actual, QIF, PDF (AI), Sure export/import, categories, merchants, rules | Pure gain. ✅ | n/a |
| **New feature areas** | n/a | bills and recurring, paycheck plan, goals, insights (preview), statement vault, many bank providers, budgets with rollover, splits, MCP | Lots to discover, with no guided tour from "Maybe" to "Sure". | Low (opportunity) |
| **Upgrade documentation** | n/a | the README points to Maybe's final release notes. **No "Upgrading from Maybe" guide in `docs/hosting/`.** | They piece it together from GitHub issues and Discord. | Medium |

#### What upgraders need

1. **An "Upgrading from Maybe v0.6.0" guide** in `docs/hosting/`: image swap, env changes (`SYNTH_API_KEY` → pick a market-data provider, `RAILS_AI_MAX_THREADS`), what the migrations do, how to roll back (database backup first), and the behaviour changes in the table above.
2. **A one-time "Welcome from Maybe" screen** on first login after the upgrade (detectable: migrations ran on a database that has Maybe-era data). In plain language, with an action for each item:
   - "Rules now run **in order** after each sync. Review your rule order." → Rules page
   - "Two free, private helpers were added: Merchant matcher and Category classifier. [On/Off]"
   - "The assistant can now **make changes** for you. [Allow changes / Read-only]" (U24)
   - "Choose where exchange rates and prices come from. [Yahoo Finance (free) / Twelve Data (key)]" (U23)
   - "New here: Bills, Goals, Insights. [Take the tour]"
3. **Keep Maybe's behaviour as the default wherever it is cheap to do so**, so the upgrade is not a behaviour change. For example: a keyless market-data default, and the assistant in read-only mode until the user opts in to write tools.
4. **Classify each Maybe → Sure difference** as *kept*, *improved* (automatic), or *changed (needs a decision)*, and show only the last group to the user.


| Coming from | Concepts they bring | Sure equivalent | Gap or confusion |
|---|---|---|---|
| **YNAB** | "Give every dollar a job", Ready to Assign, category targets, rollover (overspending covered from other categories), scheduled transactions, payees, reconcile, Age of Money | Budgets per category with rollover (`Budget::RolloverCalculator`), goals (one-off and maintained), bills / recurring, merchants, statement reconciliation, YNAB importer | **No zero-based "Ready to Assign" pool.** YNAB users will look for it first. Targets map partly to goals and partly to budgets, so make that mapping explicit. "Payee rename rules" map to merchants plus rules, but the word "merchant" is unfamiliar to them. |
| **Actual Budget** | Envelope budgeting, **rules with stages (pre / default / post)**, payees, schedules, reconcile | Ordered rules with stop-processing, merchants, bills, Actual importer | Rules map well. Actual's "pre/post" stages are similar to Sure's position order: document that mapping. Envelope budgeting has the same gap as YNAB. |
| **Mint / Copilot-style trackers** | Auto-categorized feed, budgets, net worth, alerts | Sync + AI/Bayes categorization, budgets, net worth, insights | Closest fit. These users expect categorization to *just work*: P2 needs the one-switch AI (see §3). |
| **Firefly III** (self-hosted, open source) | See §7.2 | Ordered rules, categories, tags, budgets, goals with earmarked accounts, bills, multi-currency | **No Firefly importer.** Firefly's double-entry model (expense and revenue accounts) has no direct Sure equivalent. Rule groups and "strict" rules map only partly. Firefly's tagline is "No AI, no cloud". |
| **Securo** (self-hosted, open source) | See §7.1 | Ordered rules, chat, MCP, document search, SimpleFIN and Enable Banking | No OFX or CAMT import in Sure. "Agents" with a per-agent knowledge base has no direct equivalent. Sure has no global chat shortcut. |
| **ChatGPT Finances** (OpenAI) | See §7.1 | Chat with tools, insights, bills calendar, subscription audit | ChatGPT is read-only, and Sure's assistant can *write*. ChatGPT shows what it remembers about you, and Sure has no equivalent. |

**Recommendation:** add a "Coming from…" onboarding step (Maybe v0.6.0 / YNAB / Actual / Firefly III / Mint / Securo / ChatGPT / spreadsheet / new). For Maybe upgraders it is not a question but the detected "Welcome from Maybe" screen (§7.0). It picks the importer, sets the budgeting view, and shows a 5-line glossary ("Payee = Merchant, Scheduled = Bill, Target = Goal or Budget").

### 7.1 Two AI-era reference points

These two products set expectations for exactly the users Sure's AI features target. Sources are listed at the end of the section.

**Securo** (`securo-finance/securo`, AGPL-3.0, self-hosted; FastAPI + React + Celery)

| Securo does | What its users will expect in Sure | Sure today |
|---|---|---|
| **AI is "optional, off by default"**: OpenAI, Anthropic, Ollama or any OpenAI-compatible endpoint | Off means off and invisible, and turning it on is one deliberate act | AI pages are visible with no provider, and turning AI on takes three acts (see §3, P2). **This supports U1 and U2.** |
| **⌘J global chat panel** | Chat is reachable from anywhere, alongside their data | Chat sidebar or chat page (`show_ai_sidebar`). There is no keyboard-first entry point. |
| **"Agents"** with tool use over the user's data, **plus a per-agent knowledge base (RAG)** | Several named assistants with their own documents (e.g. a "tax agent" with tax PDFs) | One assistant and one family-wide document store (`search_family_files`). One configurable assistant is simpler, and a better default for P1 and P2. Named agents are a P3 idea worth tracking. |
| Tool use runs **through a built-in MCP server**, so without it agents can't read data | MCP is how AI touches data, inside and outside the app | Sure exposes the same tool registry both to its built-in chat and over MCP (W13 and W15). Sure is already at parity or ahead here. |
| **Auto-categorization rules engine** (no AI or ML categorization mentioned) | Rules they can read and predict | Sure goes further (matcher, Bayes, AI). The risk is *losing* the predictability Securo users value. **This supports U3 and U4** (show the stages and the source of every value). |
| One-line installer (Docker or Podman), Helm chart | Install in minutes | A compose example, plus a separate AI compose. Comparable. Sure's AI compose comes with defaults that feel slow (§3). |
| Pluggy, Enable Banking, SimpleFIN; **OFX / QIF / CAMT / CSV** import | Their bank-export formats work | QIF, CSV, PDF (AI), YNAB, Actual, Mint, but **no OFX or CAMT**. Common European bank exports would have to go through CSV or PDF-via-AI. |
| Workspaces with **owner / editor / viewer** roles (synced from OIDC) | Clear roles | admin / member / guest per family, plus super-admin. Equivalent. The scoping issues in §4 apply. |

**ChatGPT Finances** (OpenAI, launched 2026-05-15 for US Pro users, later Plus and Free/Go in the US)

| ChatGPT Finances does | What its users will expect in Sure | Sure today |
|---|---|---|
| **Zero setup**: "@Finances, connect my accounts" via **Plaid** (12,000+ institutions) | Connecting accounts *is* the setup, with no provider keys | Plaid needs operator credentials on self-hosted instances. Persona 1 or 2 coming from ChatGPT faces bank and AI configuration that ChatGPT hides. **The hosted Sure path and the U2 one-flow matter most for this group.** |
| **Dashboard**: spending, **subscriptions**, **upcoming payments**, portfolio performance | These four views first | All four exist (spending/insights, subscription audit, bills calendar and paycheck plan, investments), but are spread across pages and **Insights is preview-gated**. **This supports U17** and a "Finances overview" landing view. |
| Conversational examples: "*Has anything changed in my spending?*", "*Plan to buy a house in 5 years*" | Ask in plain language, get a plan | Chat plus spending-anomaly insights answer the first. The second needs **goals plus a plan layer**, which **supports U15** (plan templates the assistant can coach against). |
| **Read-only** access (it can't move money or change accounts) | AI doesn't change things without asking | **Sure's assistant can write**: create rules, update, create or delete transactions, update budgets, apply rules. Rule tools already need a preview token before a rule is activated ([#3990](https://github.com/we-promise/sure/issues/3990)), but the *model* satisfies that safeguard itself; it is not a human confirmation. Transaction, budget and category writes have no safeguard at all. This is a capability advantage *and* a trust gap. **New U18:** confirm before AI writes (or a household "AI may change data" switch), plus an activity log (U13). |
| **Financial memories you can view and delete** | See what the AI "knows" and remove it | Sure has chat history, family AI prompts and the categorization cache, but no "what the assistant knows about me" view. **New U19:** a "What AI uses" page showing session context, prompts and stored documents, each deletable. |
| **Disconnect, and synced data is deleted after 30 days** | A clear data-lifetime promise | Self-hosted Sure keeps everything locally, which is a stronger story. Tell it in the UI ("Your data stays on this server. AI providers see only what you send them."). Pair it with the consent fix (U7). |
| Built a **personal-finance benchmark** with experts; "not a replacement for financial advice" | Quality claims and a disclaimer | Sure has an eval framework (W23) and a system prompt that forbids product advice. Publishing *user-visible* quality ("Categorization got 87% right last month", see U8) is the self-hosted analogue. |

**What this means for the three personas**
- **P1 (no LLM):** Securo's "off by default and invisible" is the bar. Sure should meet it (U1).
- **P2 (simple LLM):** ChatGPT has set the bar at *no setup, chat-first, four dashboard cards*. Sure can't match the zero setup on self-hosted, but it can match the *experience*: one "Turn on AI" flow (U2), an overview landing page (U17), and plans the assistant can coach against (U15).
- **P3 (custom):** Securo's per-agent knowledge bases and MCP-first design show where power users are heading. Sure's shared tool registry (chat and MCP) is already strong. The gaps are visibility and trust: write confirmation (U18), memory view (U19) and the activity log (U13).

Sources: [Securo on GitHub](https://github.com/securo-finance/securo) · [OpenAI: ChatGPT for personal finance](https://openai.com/index/personal-finance-chatgpt/) (page returned 403, so details were taken from the coverage below) · [TechCrunch, 2026-05-15](https://techcrunch.com/2026/05/15/openai-launches-chatgpt-for-personal-finance-will-let-you-connect-bank-accounts/) · [American Banker](https://www.americanbanker.com/news/openai-launches-personal-finance-tools-for-chatgpt-pro-users) · [MacRumors](https://www.macrumors.com/2026/05/15/chatgpt-personal-finance/) · [9to5Mac, expansion](https://9to5mac.com/2026/06/30/openai-just-released-new-personal-finance-features-for-chatgpt-customers/) · [ChatGPT release notes](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)

### 7.2 Firefly III

Firefly III is the most established self-hosted open-source finance manager. Its users are often the most likely to try Sure: they are already self-hosting, already privacy-minded, and often looking for a friendlier UI. Its tagline is "**No AI, no cloud and privacy-friendly.**" Firefly III users are **persona 1 by conviction**, not by lack of setup.

| Firefly III concept | What its users expect | Sure equivalent | Gap / confusion |
|---|---|---|---|
| **Double-entry bookkeeping**: every transaction moves money from a source account to a destination account | "Where did it go?" is an account, not just a category | Single-entry entries per account. Transfers are matched pairs (W2), suggested by the app and confirmed by the user | Firefly users think in source → destination. Show transfers as "from → to" and explain once that Sure is not double-entry. |
| **Asset / expense / revenue / liability accounts** (expense and revenue accounts act as payees) | Payees are accounts with history and totals | Asset and liability accounts. Payees are **merchants**. Income sources are categories or merchants | Their many "expense accounts" will look like merchants to Sure. An importer must map expense and revenue accounts to merchants, **not** create one Sure account per payee. |
| **Withdrawal / deposit / transfer** as explicit transaction types | The type is set at entry and never guessed | Sign plus `kind`. Transfers are detected and confirmed | Firefly transfers are explicit. Import them as **confirmed** transfers, not as pending suggestions. |
| **Budgets** (with available amounts per period) | Assign money per budget per period | Category budgets with rollover | Firefly budgets are **independent of categories**, while Sure budgets *are* categories. An importer must choose: budgets become categories (loses the category dimension), or categories stay and budgets become tags (loses budget amounts). Ask the user. |
| **Categories and tags** | Both used freely | Categories (hierarchical) and tags | Direct mapping. |
| **Piggy banks** (save toward a goal, linked to an asset account) | Earmark part of an account balance for a goal | **Goals with earmarked accounts** (`goal_accounts.allocated_amount`), pledges, maintained reserves | Good match. Call it out in the glossary ("Piggy bank = Goal"). |
| **Subscriptions** (formerly "bills") and **recurring transactions** | Expected charges plus auto-created recurring entries | Bills / recurring detection, paycheck plan | Sure *detects* recurring charges, while Firefly *creates* them from a schedule. Users who used Firefly recurring transactions for manual accounts will look for scheduled auto-entry. |
| **Rules in rule groups**: triggers and actions. **Strict** (all triggers) vs non-strict (any). Inverted triggers ("NOT"). Actions can set category, budget, tags, or link to a subscription or piggy bank | Rule groups as folders, group order, AND/OR per rule | One ordered list, conditions with a compound group (one level), "stop processing", classifier and AI steps as rules | **No rule groups**, so a large rule set lands as one long flat list. Strict or non-strict maps to the compound condition, but nesting is limited. **Rules can't set a budget or a goal.** Importing rules is possible (`RuleImport` exists) but needs a Firefly mapping. |
| **Data importer**: CSV, **CAMT.052 / CAMT.053**, bank connections via third-party providers (GoCardless/Nordigen, Salt Edge/Spectre) | Bank exports and open-banking sync | CSV, QIF, PDF (AI), Enable Banking, SimpleFIN, Plaid and others | **No CAMT** (also needed for Securo users, U20). European Firefly users mostly sync via GoCardless or Salt Edge, and Sure's **Enable Banking** is the path to steer them to. |
| **REST JSON API**, webhooks | Scripts and automations against their data | API v1, MCP | Sure's API plus MCP covers this. Document the Firefly-script equivalents. |
| **"No AI"** | AI absent, not just disabled | AI pages visible without a provider. Matcher and Bayes rules added automatically | Make the explanation explicit: Sure's matcher and Bayes are **local, free, and send nothing out**. Firefly users will accept them if the UI says so and will distrust them if it doesn't. This strengthens U1 (tiers) and U3 (stage picture with "private" labels). |

**Migration path today:** export transactions from Firefly III as CSV, then use Sure's CSV transaction import with column mapping. This carries transactions, categories, tags and notes, but **loses** account types, budgets, piggy banks, subscriptions, recurring schedules and rules, and leaves transfers to be re-matched by W2.

**Proposed `FireflyImport`** (like `SureImport`): read the Firefly API with a personal access token and map:
- asset and liability accounts → accounts;
- expense and revenue accounts → merchants;
- withdrawals, deposits and transfers → entries and confirmed transfers;
- categories and tags → categories and tags;
- piggy banks → goals with earmarks;
- subscriptions → bills;
- budgets → the user's choice (categories or tags plus budget amounts);
- rules → rules, flattening groups in group order and preserving strict/non-strict as a compound condition, with a skip-list for actions that have no equivalent.

A dry-run report ("this will import 3 groups / 41 rules; 5 actions are not supported") turns a risky migration into an informed one.

Sources: [Firefly III on GitHub](https://github.com/firefly-iii/firefly-iii) · [Firefly III data importer](https://github.com/firefly-iii/data-importer) · [Firefly III rules](https://docs.firefly-iii.org/how-to/firefly-iii/features/rules/) · [rule triggers](https://docs.firefly-iii.org/references/firefly-iii/rule-triggers/) · [rule actions](https://docs.firefly-iii.org/references/firefly-iii/rule-actions/)

---

## 8. Do the workflows resemble popular personal-finance concepts?

> **Related PRs:** [#4083](https://github.com/we-promise/sure/issues/4083) net worth velocity and momentum · [#3952](https://github.com/we-promise/sure/issues/3952) investing counted as saving · [#3974](https://github.com/we-promise/sure/issues/3974) multi-currency goal funding · [#4432](https://github.com/we-promise/sure/issues/4432) *(open, v0.7.7)* crypto accounts fund goals · [#3428](https://github.com/we-promise/sure/issues/3428) *(open, v0.7.7)* refunds reduce spending · [#3498](https://github.com/we-promise/sure/issues/3498) *(open, v0.7.7)* physical cash account · [#4343](https://github.com/we-promise/sure/issues/4343) *(open, v0.7.7)* loan principal split · [#3054](https://github.com/we-promise/sure/issues/3054) *(closed, v0.7.7)* EMI installment plans · [#3858](https://github.com/we-promise/sure/issues/3858) *(open, v0.7.6)* Plan hub

| Book | Core idea people quote | Sure today | Gap / opportunity |
|---|---|---|---|
| **The Barefoot Investor** (Pape) | Buckets: Daily Expenses (Blow), Splurge, Smile (long-term), Fire Extinguisher (emergencies and debt). "Mojo" = a cash buffer. Automate on payday. | **Maintained goals in months of expenses** (≈ Mojo). **Paycheck plan** (what's due per pay period, what's safe). Idle cash insight. | No **bucket plan** that splits each paycheck by percentage. Goals plus the paycheck planner are 80% of it, so a "Barefoot buckets" template would be mostly configuration. |
| **I Will Teach You to Be Rich** (Sethi) | Conscious Spending Plan: Fixed costs 50–60%, Investments 10%, Savings 5–10%, Guilt-free 20–35%. Automate. Cut costs ruthlessly on what you don't love. | Budgets, savings-rate insight, **subscription audit** (cut what you don't love), recurring detection. | No **CSP view** (category groups as % of take-home). The subscription audit plus spending-anomaly insights fit the "spend extravagantly on what you love" message well, so frame them that way. |
| **The Richest Man in Babylon** (Clason) | Pay yourself first (save 10%), control expenditures, make your gold multiply, guard against loss, own your home. | Savings-rate change insight, budgets, idle cash (make it multiply), investments, property valuations. | No **"pay yourself first" check** ("did ≥10% of this month's income go to savings or investments before spending?"). This is easy to derive from transfers to savings or investment accounts. |
| **Rich Dad Poor Dad** (Kiyosaki) | Assets put money in your pocket, liabilities take it out. Cash flow. Passive vs earned income. | Balance sheet (assets / liabilities), net worth milestones, cash-flow warning, income statement. | Sure's "asset" is the *accounting* asset (a house counts). Kiyosaki's is *cash-flowing*. No **passive vs earned income** classification. A category flag ("passive income") plus a "passive income covers X% of expenses" metric would be a small, motivating addition. |
| **Die With Zero** (Perkins) | Spend on experiences while you can, time buckets, net-worth peak, plan the drawdown. | Net worth tracking, goals, forecasting pieces. | No **drawdown or peak** projection. It's out of scope for now, but goals with target *dates* and "age" context would open the door. |
| **Total Money Makeover** (Ramsey) and debt books | Baby steps, emergency fund, **debt snowball / avalanche** | Emergency fund (maintained goal), loan accounts | No **debt payoff plan** (snowball vs avalanche ordering, payoff date). A frequent request from this audience. |
| **Psychology of Money** (Housel) | Savings rate over returns, room for error, enough | Savings-rate insight, reserve goals | Good alignment. The insight copy could cite the concept ("room for error"). |

**Overall:** Sure's *signals* (insights, reserve goals, paycheck plan, subscription audit) already speak the language of these books, better than most open-source finance apps. What's missing is the **plan layer** readers adopt from these books: a named framework that turns the signals into "you're on plan / off plan".

**Opportunity: plan templates.** Each one is configuration over existing primitives:

| Template | Built from |
|---|---|
| Barefoot buckets | category groups → buckets with %, paycheck plan, maintained goal "Mojo = 3 months" |
| IWT Conscious Spending Plan | category groups as % of take-home, savings and investment transfers, subscription audit |
| 50/30/20 | needs / wants / savings groups with % |
| Pay yourself first (Babylon) | a savings-transfer check per payday |
| Zero-based (YNAB-style) | budget view that shows unassigned income |
| Debt snowball / avalanche | loan accounts ordered by balance or rate, payoff projection |

The assistant and insights can then refer to the chosen plan ("You're 4% over your guilt-free spending this month"). That makes the AI feel like a coach for the user's own framework instead of a generic chatbot.

---

## 9. Out-of-the-box defaults: recommendations per tier

| Tier | Defaults that should be guaranteed | Hide |
|---|---|---|
| **Off (P1)** | Classifier rules on, with a visible learning-progress cue. Transfer matching on. Insights on (un-preview when stable). Bills detection on. | AI prompts, LLM usage, MCP, AI rule actions, AI sections of Self-hosting, the chat entry point (or show "Turn on AI" there) |
| **Simple (P2)** | One "Turn on AI" flow: choose **Cloud** (paste a key, recommended model preselected) or **Local** (a detected Ollama, with a recommended model *and* context window). It enables chat consent for the admin, creates an "AI categorize" rule *below* the classifier, and runs a 1-click health check. Context window set from the model (not 2,048). Chat streaming where possible, with progress text otherwise. AI-set values **suggested, not locked**, until the user accepts or 7 days pass. | Classifier tuning knobs, prompts, JSON mode, shadow, Jev |
| **Custom (P3)** | Per-task routing ([#4245](https://github.com/we-promise/sure/issues/4245)). An **effective-config page** (value plus source: ENV / Setting / default). An optional declarative `ai.yml` an agent can write and a human can diff. An activity log per agent or API key. | nothing, but group under Expert |

**Design rule:** *a default must never look like a bug.* If the hardware or model can't support a feature at an acceptable speed (e.g. tool-calling chat on a small local model), the default should be to **offer** the feature with a warning, not to enable it silently.

---

## 10. Summary of recommendations (user-facing)

> **Related PRs:** [#3694](https://github.com/we-promise/sure/issues/3694) *(open, v0.7.7)* supports U2/U11 · [#3990](https://github.com/we-promise/sure/issues/3990) partial U18 · [#4021](https://github.com/we-promise/sure/issues/4021) reuse for U22 · [#4328](https://github.com/we-promise/sure/issues/4328) context for U23 · [#3858](https://github.com/we-promise/sure/issues/3858) *(open, v0.7.6)* supports U15/U17 · [#3442](https://github.com/we-promise/sure/issues/3442) *(open, v0.7.7)* supports U5/U9 · [#4283](https://github.com/we-promise/sure/issues/4283) *(open, v0.7.6)* MCP-only scope, groundwork for U18

| # | Recommendation | Persona | Effort | Value |
|---|---|---|---|---|
| U1 | Setup tier switch (Off / Simple / Custom) that filters settings and nav | all | M | High |
| U2 | One "Turn on AI" flow (provider, consent, AI rule, health check) | P2 | M | High |
| U3 | One "Auto-categorize" picture: the stage list, with system steps shown as system steps | P1, P2 | S | High |
| U4 | Source chip, "Why this category?" panel, and "This is wrong" | all | M | High |
| U5 | "Report a problem" redacted bundle / pre-filled issue | all | M | High (maintainers too) |
| U6 | Fix scopes: instance to super-admin, personal prefs per user, a household AI page | all | M | High (safety) |
| U7 | Consent policy for family AI rules (skip non-consenting members' accounts, or a household notice) | P2, P3 | S | High (trust) |
| U8 | Classifier page: plain-language default view, knobs under Expert | P1, P2 | S | Medium |
| U9 | Learning-progress cue for Bayes during cold start | P1 | S | Medium |
| U10 | AI results as suggestions (confirm, like transfers) instead of hard locks, or with auto-accept after N days | P2 | M | Medium |
| U11 | Local-model defaults: context window from the model, streaming or progress text, recommended models | P2 | S | Medium |
| U12 | Effective-config page and an optional `ai.yml` for agent-managed setups | P3 | M | Medium |
| U13 | Agent / API-key activity view, including MCP tool calls (today they go only to the log). Pipelock's MCP proxy can keep signed receipts, but only for operators who run it, only outside Sure, and only for clients that connect through it | P3 | M | Medium |
| U14 | "Coming from…" onboarding with an importer and glossary | migrants | S | Medium |
| U15 | Plan templates (Barefoot, CSP, 50/30/20, zero-based, pay-yourself-first, debt snowball) | all | L | High (differentiator) |
| U16 | Make onboarding goals do something (e.g. "AI insights" → the Turn on AI flow) | all | S | Low-medium |
| U17 | Un-preview Insights when stable, and add a "Finances overview" landing view (spending, subscriptions, upcoming bills, investments) | all | S | Medium |
| U18 | Confirm before the assistant writes data, or a household "AI may change data" switch. Extend the preview-token pattern of [#3990](https://github.com/we-promise/sure/issues/3990) from rules to all writes, with a human confirming. For MCP: add a read-only MCP scope beside `mcp` and mark write tools with `destructiveHint`. Pipelock's MCP proxy scans tool calls but asks no one, so it doesn't replace this | P2, P3 | S | High (trust) |
| U19 | A "What AI uses" page: session context, prompts and documents, each viewable and deletable | P2, P3 | M | Medium |
| U20 | OFX / CAMT import (Securo, Firefly III data-importer users, European bank exports) | migrants | M | Medium |
| U22 | "Upgrading from Maybe v0.6.0" hosting guide and a one-time in-app "Welcome from Maybe" screen with an action per behaviour change (reuse the What's new dialog, [#3505](https://github.com/we-promise/sure/issues/3505), [#4021](https://github.com/we-promise/sure/issues/4021)) | Maybe upgraders | S–M | **Highest** (largest existing user base) |
| U23 | A keyless market-data default (Yahoo Finance), or a fallback when the chosen provider has no key, plus a visible warning when rates or prices are not updating | all, especially Maybe upgraders | S | High |
| U24 | Re-ask AI consent when the assistant's capabilities expand (read-only → write tools), with a read-only mode | Maybe upgraders, P2 | S | High (trust) |
| U21 | `FireflyImport` via the Firefly API (accounts, expense/revenue accounts → merchants, transfers, piggy banks → goals, subscriptions → bills, rules with groups flattened), with a dry-run report | Firefly III migrants | L | High (largest self-hosted source audience) |

---

## 11. Caveats

- This is based on the workflow map, the settings and onboarding views, and the model and schema at `56105a3b5`. It was not checked with usability testing or user interviews.
- Persona 2's local-model experience comes from the shipped compose defaults, the compose file's own comments, and one instance's measurements (chat waiting 56–104 s behind background AI). Other hardware and models will differ.
- The Maybe v0.6.0 comparison reads the `v0.6.0` tag's code, not a running Maybe instance. The disabled-rules behaviour is confirmed by Sure's fix in [#552](https://github.com/we-promise/sure/issues/552).
- Firefly III is summarized from its GitHub READMEs and rules documentation. Budget rollover and auto-budget details were not re-verified.
- Securo is summarized from its GitHub README. ChatGPT Finances is summarized from press coverage and OpenAI's release notes (OpenAI's announcement page refused automated access), so details may lag their current versions.
- The book summaries are the commonly quoted frameworks, simplified, not complete descriptions.
