# Instruction consolidation: preservation map

This map was written before the instruction rewrite, against `main` at
`947fe8327c6eac31f218d350b8dd5f865d5036fc` (2026-09-06 UTC).
The new branch starts there. [PR #3403](https://github.com/we-promise/sure/pull/3403)
is reference material only; none of its commits are in this branch's ancestry.
This document records the migration decision, not additional operating rules.

## Inventory and disposition

The inventory covers tracked files, references to instruction files, ignored generated
instruction paths, and deleted/renamed sources in reachable `main` history. Personal
instructions outside this repository are outside the consolidation.

| Source on main | Disposition | What survives / why |
| --- | --- | --- |
| `AGENTS.md` (uppercase; no separate `Agents.md`) | Preserve, shorten | Canonical repository rules, required checks, design-system enforcement, API obligations; detailed material moves to shared guides. |
| `CLAUDE.md` | Thin adapter | Native `@AGENTS.md` import; commands, testing, architecture and UI guidance move to shared docs. Strict pre-PR gate survives. |
| `.github/copilot-instructions.md` | Thin adapter | Explicit link to canonical guidance and relevant shared guides; remove duplicated prose and inapplicable `applyTo` frontmatter. |
| `.junie/guidelines.md` | Thin adapter | Retain legacy discovery path with a link to canonical guidance; the frozen nine-rule copy is no longer maintained separately. |
| `.gemini/config.yaml` | Preserve unchanged | Gemini Code Assist review configuration, including disabled reviews, summary settings, severity and ignore patterns. It is not Gemini CLI context. No new Gemini integration is introduced. |
| `.cursor/rules/general-rules.mdc` | Thin always-on adapter | Canonical entry point; operational restrictions and current-user/family conventions survive. |
| `.cursor/rules/project-conventions.mdc` | Move, retire duplicate | Model/PORO/concern design, dependency discipline, Hotwire, simplicity and validation conventions move to `architecture.md`. |
| `.cursor/rules/project-design.mdc` | Thin adapter | Architecture/data-flow guide; retain always-on loading. Correct verified stale descriptions. |
| `.cursor/rules/testing.mdc` | Thin scoped adapter | `testing.md`; retain `test/**` scope. |
| `.cursor/rules/view_conventions.mdc` | Thin scoped adapter | `ui.md`; retain view/JavaScript/component-JavaScript scopes. |
| `.cursor/rules/stimulus_conventions.mdc` | Thin adapter | `ui.md`; retain manual rule availability. |
| `.cursor/rules/ui-ux-design-guidelines.mdc` | Thin always-on adapter | `design-system.md` (split from `ui.md` so the always-on adapter stays design-only); preserve global design restrictions and explicit permission requirement for new global styles. |
| `.cursor/rules/api-endpoint-consistency.mdc` | Thin scoped adapter | Shared API checklist; retain exactly the three API v1 scopes and `alwaysApply: false`. |
| `.cursor/rules/cursor_rules.mdc` | Retire generic template | Cursor rule format/loading reference belongs in `harness-adapters.md`; Prisma examples do not describe this Rails app. |
| `.cursor/rules/self_improve.mdc` | Retire automatic trigger | Keep guidance maintenance advice in `harness-adapters.md`; intentionally stop always-on instructions to generate new rules when patterns occur in three files. |
| `docs/llm-guides/adding-a-securities-provider.md` | Preserve in place | Detailed repeatable provider workflow, registry, MIC/currency handling, configuration, UI/locales and verification. |
| `docs/llm-guides/gating-a-preview-feature.md` | Preserve in place | Feature gate and rollout workflow. |
| `docs/llm-guides/goals.md` | Preserve in place | Goals domain, reconciliation, statuses and data guidance. |
| `docs/llm-guides/wealth-agent-harness.md` | Preserve in place | Product integration boundary, read-only tools, provenance and monthly runbook. Not repository-wide coding policy. |
| `docs/llm-guides/wealth-blueprint.md` | Preserve in place | Reference architecture for an external wealth/tax project, including its own operating protocol. Its working-memory instructions do not redefine this repository's root files. |
| `CONTRIBUTING.md` | Update entry links | House rules, contribution workflow and CI review gate remain; replace vendor-specific convention link. |
| `bin/update_structure.sh` and ignored `.cursor/rules/structure.mdc` | Preserve, document legacy status | Optional generated tree helper, not a policy source. Existing generator defects are separate from this consolidation. |
| `bin/codex-env` | Preserve, document legacy status | Linux environment bootstrap, not repo guidance or a skill; it changes system auth and can mask Ruby-version mismatches. Do not promote it as the standard setup. |
| Ignored editor, agent, MCP and generated-workflow paths in `.gitignore` | Preserve exclusions | Local/generated context, not tracked shared policy; complete categories are listed below. |
| `test/api_endpoint_consistency_rule_test.rb`, `test/support/verify_api_endpoint_consistency.rb` | Update existing checks | Check the shared API guide and adapter reference/scopes instead of requiring full policy prose inside Cursor. Keep compliance scanning. |
| `.github/workflows/*`, `.github/ISSUE_TEMPLATE/*`, `.github/DISCUSSION_TEMPLATE/*`, `.rubocop.yml`, `.erb_lint.yml`, `biome.json`, `.editorconfig`, `.devcontainer/*`, `.env*.example`, `package.json`, `Gemfile`, `.ruby-version` | Preserve | Executable checks, contributor templates, style and environment configuration; useful evidence, not replacement prose to copy into adapters. |
| `app/models/assistant/**`, provider LLM prompt implementations, settings for AI prompts, `app/models/eval/**`, `db/eval_data/*.yml`, `test/models/eval/**`, `lib/tasks/evals.rake`, `.github/workflows/llm-evals.yml`, `docs/hosting/ai.md`, `docs/hosting/mcp.md` | Preserve | Runtime product behavior, evals and user-facing integration documentation; no prompt or application behavior changes. |
| Comments in fixtures/migrations referring to `CLAUDE.md` | Preserve | Historical attribution, not active instruction entry points; unnecessary application/fixture churn is avoided. |

No tracked `GEMINI.md`, nested `AGENTS.md`, `SKILL.md`, `.claude/`, `.codex/`,
`.agents/skills/`, Windsurf, Cline, Aider, Roo or Continue instruction source exists at
the audited base. Historical sources and deleted files are recorded below.

The ignored instruction/configuration categories in [`.gitignore`](../../.gitignore)
are legacy editor rules (`.cursorrules`, `.windsurfrules`, `*.roo*`); generated
Cursor rules (`structure.mdc`, `agent.mdc`, `dev_workflow.mdc`, `taskmaster.mdc`);
local Claude/Codex state (`.claude/settings.local.json`, `.claude_settings.json`,
`.codex`); Auto Claude state (`.auto-claude/`, `.auto-claude-security.json`,
`.auto-claude-status`, `.security-key`, `logs/security/`); Taskmaster state
(`.taskmaster/`, `.taskmasterconfig`, `tasks.json`); MCP configuration
(`*.mcp.json`, `.cursor/mcp.json`, `.playwright-mcp`); and generated workflow
material (`docs/superpowers/`, `scripts/`). These are exclusion patterns, not
claims that any contributor's ignored files exist or contain shared policy.

## Preservation by subject

| Subject | Destination | Decision |
| --- | --- | --- |
| Setup, daily commands, prohibited server/restart/credentials/automatic migration actions | `AGENTS.md`, `development.md` | Preserve restrictions; setup/migration commands are references for explicitly requested environment work. |
| Pre-PR tests, ERB/Ruby lint, security, applicable system tests, clean Biome and CI | `AGENTS.md`, `development.md` | Adopt the existing strict Claude gate globally; explicitly stronger for other entry points (see below). |
| Dependency restraint, model-owned business logic, concerns, database vs model validations, performance tradeoffs | `architecture.md` | Preserve, including traits-based concerns and avoiding N+1/global-layout overhead. |
| Family ownership, account/entry delegated types, amounts, valuations/trades, transfers, syncs, provider concepts/Provided concerns | `architecture.md` | Preserve concepts; update names/paths and qualify claims using current code. |
| Minitest/fixtures/Mocha/OpenStruct, minimal fixtures, edge cases, VCR, commands vs queries, sparing system tests | `testing.md` | Preserve; RSpec remains an explicit documentation-only exception. |
| Functional tokens, DS-first, repeated-shape extraction and reviewer severity | `AGENTS.md`, `design-system.md` | Preserve every requirement and escalation level. |
| Permission for new global styles, semantic HTML, Turbo/query state, ViewComponent vs partial, declarative Stimulus, <7-target aim, localization/accessibility | `ui.md` | Preserve; replace obsolete examples and hardcoded UI text. |
| API behavioral coverage, errors/scopes, docs-only rswag, API-key pattern, regeneration after changes and checklist after commits | `api-endpoint-consistency.md` | Preserve; remove already-resolved OAuth TODO only. Runtime OAuth support remains. |
| Provider diagnostics, namespaced extras, pending/FX, defaults/precedence, raw payload privacy | `providers.md` | Preserve obligations and Up local-only privacy restriction; correct descriptions of current behavior. |

## Intentional policy decisions

1. **Pre-PR gate becomes uniform and therefore stronger for some harnesses.**
   Claude required all Rails tests, applicable system tests, RuboCop with safe
   autocorrection, ERB lint with autocorrection and Brakeman before *every* PR,
   with creation allowed only when all checks pass. Copilot copied the check list.
   AGENTS required green tests before pushing and clean Ruby/Biome but Brakeman
   only before major PRs; Cursor/Junie lacked the same explicit creation gate.
   Preserve the strict gate and AGENTS' additional Biome requirement in canonical
   guidance. Do not silently substitute focused tests, changed-file lint or
   merely reporting failures for that gate. CI configuration is unchanged.
2. **Retire the Rails 7.2-only migration restriction.** It explicitly prohibited
   8.0 in older Cursor/Junie instructions; current Rails is 8.1. New migrations
   follow the current Rails version, while historical migration superclass
   versions stay intact. This is a deliberate removal of a version-era constraint.
3. **Retire automatic rule proliferation.** The `self_improve` rule's three-file
   trigger is removed. Maintain shared guidance when relevant; do not create
   duplicate harness-specific policies as a side effect of ordinary coding.
4. **Use current UI conventions and the established rswag exception.** Remove
   old hardcoded-string advice, obsolete component examples and blanket no-RSpec
   phrasing that conflicts with later mandatory OpenAPI documentation policy.
   No permission or design-review requirement is relaxed. Setup/database command
   references are explicitly limited to requested environment work: this makes
   the existing no-automatic-migrations restriction explicit for setup and related
   database tasks, rather than treating command listings as standing authorization.
5. **No skills introduced.** Provider addition and preview gating are genuine
   repeatable workflow candidates, but existing shared guides already serve every
   supported harness, and Rails provider generators already exist in
   `lib/generators/provider/`. There is no demonstrated invocation, packaging or
   execution benefit that warrants a skill wrapper for this change. Runtime wealth
   operating protocols are not repository coding skills.

## History reviewed

Review window: 2025-09-01 through 2026-09-06 UTC (more than one year), plus
earlier introductions to explain inherited policy. The audit used `git ls-files`
for the base inventory, repository-wide reference searches, and `git log` rooted
at the fixed base commit with `--since-as-filter='2025-09-01T00:00:00Z'`,
`--until='2026-09-07T00:00:00Z'`, and `--name-status`, followed by patch inspection.
Deleted/renamed files were checked with `--diff-filter=DR`. All parent ancestry
was included; neither `--first-parent` nor `--all` defined the policy baseline.
Dates below are **committer dates normalized to UTC**, obtained with
`TZ=UTC git show --date=format-local:%Y-%m-%d --format='%h %cd %s'`.
PR #3403's diff and review comments were inspected separately, not merged or
cherry-picked. Its [9f44bee07](https://github.com/we-promise/sure/commit/9f44bee07) commit is not an ancestor of the audited base.

| Date | Commit | Evolution and consequence |
| --- | --- | --- |
| 2025-02-04 | [2a338eb01](https://github.com/we-promise/sure/commit/2a338eb01) | Cursor architecture/conventions introduced; contributor guidance points readers there. |
| 2025-03-28 | [2f6b11c18](https://github.com/we-promise/sure/commit/2f6b11c18) | General AI rules and the generated Cursor structure helper introduced. |
| 2025-05-26 | [07ca33f2f](https://github.com/we-promise/sure/commit/07ca33f2f) | Taskmaster scaffolding adds generic Cursor-rule authoring and self-improvement templates. |
| 2025-06-17 | [b803ddac9](https://github.com/we-promise/sure/commit/b803ddac9) | CLAUDE introduced alongside API v1 work. |
| 2025-06-20 | [fcf14f5f2](https://github.com/we-promise/sure/commit/fcf14f5f2) | Claude's explicit all-checks-pass pre-PR gate introduced; still present at base. |
| 2025-08-15 | [fb6e094f7](https://github.com/we-promise/sure/commit/fb6e094f7) | Gemini Code Assist reviews explicitly disabled; settings unchanged since. |
| 2025-08-27 | [c99335147](https://github.com/we-promise/sure/commit/c99335147) | AGENTS introduces a shorter, different checklist; not evidence of repealing Claude's gate. |
| 2025-09-16 | [e00599516](https://github.com/we-promise/sure/commit/e00599516) | Context file updates; parallel instruction maintenance continues. |
| 2025-09-20 | [60f54f9ba](https://github.com/we-promise/sure/commit/60f54f9ba) | Copilot gets another substantial copy, including pre-PR commands. |
| 2025-09-21 | [2892ebb2f](https://github.com/we-promise/sure/commit/2892ebb2f) | Codex Linux environment helper added. |
| 2025-09-23 | [7245dd79a](https://github.com/we-promise/sure/commit/7245dd79a) | Cursor cleanup adds the temporary Rails 7.2-only migration restriction. |
| 2025-10-28 | [391011628](https://github.com/we-promise/sure/commit/391011628) | Claude switches from temporary hardcoded English advice to mandatory localization. |
| 2025-11-14 | [972648b66](https://github.com/we-promise/sure/commit/972648b66) | Codex helper updated for Ruby 3.4.7; not a portable runtime contract. |
| 2025-11-16 | [066fdf4ed](https://github.com/we-promise/sure/commit/066fdf4ed) | Junie copies nine Cursor rules; later source changes do not automatically reach the copy. |
| 2025-12-19 | [664c6c2b7](https://github.com/we-promise/sure/commit/664c6c2b7) | SimpleFIN/Plaid pending + FX guidance added. |
| 2026-01-10 | [3658e812a](https://github.com/we-promise/sure/commit/3658e812a) | Pending defaults/reconciliation change; Claude updated while AGENTS retains default-off prose. |
| 2026-01-22 | [3f5fff27e](https://github.com/we-promise/sure/commit/3f5fff27e) | Lunchflow pending support reaches AGENTS; Claude's unsupported claim persists. |
| 2026-01-30 | [9f5fdd4d1](https://github.com/we-promise/sure/commit/9f5fdd4d1) | Mandatory rswag documentation exception added. |
| 2026-02-10 | [8fcd2912c](https://github.com/we-promise/sure/commit/8fcd2912c) | Post-commit API behavioral/docs/auth checklist and verification introduced. |
| 2026-03-16 | [a0b1029ba](https://github.com/we-promise/sure/commit/a0b1029ba) | Contributor guide documents automated Pipelock security scanning. |
| 2026-04-06 | [616c363b3](https://github.com/we-promise/sure/commit/616c363b3) | Devcontainer Selenium guidance added. |
| 2026-04-10 | [0aca297e9](https://github.com/we-promise/sure/commit/0aca297e9) | Securities-provider shared guide added. |
| 2026-05-01 | [e250d266e](https://github.com/we-promise/sure/commit/e250d266e) | Design-token source evolves; link to current design system. |
| 2026-05-10 | [712d6baca](https://github.com/we-promise/sure/commit/712d6baca) | AGENTS adds DS reuse and reviewer escalation policy, absent from old copies. |
| 2026-05-18/19 | [5249842c7](https://github.com/we-promise/sure/commit/5249842c7), [e8ce28648](https://github.com/we-promise/sure/commit/e8ce28648) | Beta gating guide introduced, then deleted and replaced with the preview guide. |
| 2026-06-02 | [3508f7058](https://github.com/we-promise/sure/commit/3508f7058) | Goals guide introduced. |
| 2026-06-14 | [88343002d](https://github.com/we-promise/sure/commit/88343002d) | Rails 7.2 → 8.1 upgrade supersedes the old migration-version prohibition. |
| 2026-06-15 | [08bfd4377](https://github.com/we-promise/sure/commit/08bfd4377) | Support-relevant provider diagnostics required in DebugLogEntry. |
| 2026-06-20 | [dc2a565b6](https://github.com/we-promise/sure/commit/dc2a565b6) | Up raw logging privacy constraint added to Claude. |
| 2026-07-26 | [375dd060d](https://github.com/we-promise/sure/commit/375dd060d) | Preview gate guide updated for insights. |
| 2026-08-04 | [efb7cc393](https://github.com/we-promise/sure/commit/efb7cc393) | Wealth blueprint and external agent harness docs added; preserve their separate product scope. |
| 2026-08-16 | [acf4cb201](https://github.com/we-promise/sure/commit/acf4cb201) | Goals deletion semantics updated; preserve current guide. |

The only deleted instruction source in the scoped main-history window is
`docs/llm-guides/gating-a-beta-feature.md`, replaced by the preview guide in
[e8ce28648](https://github.com/we-promise/sure/commit/e8ce28648). Other local refs expose `.cursor/rules/localization.mdc`,
`docs/llm-guides/rails-provider-generator.md`, and earlier
`patrimonial-agent-harness.md` / `patrimonial-blueprint.md` names, but those file
histories are not reachable from the audited main base. They are not resurrected
as main policy; the wealth-named guides entered main directly in [efb7cc393](https://github.com/we-promise/sure/commit/efb7cc393).

## Factual corrections, not product changes

| Stale description | Current source evidence |
| --- | --- |
| User-owned accounts; all values stored in a user's base currency | [Account](../../app/models/account.rb) belongs to `Family`; both accounts and [entries](../../app/models/entry.rb) require their own currency. |
| Nested provider concepts and old balance-calculator paths | [Provider registry](../../app/models/provider/registry.rb), [exchange-rate concept](../../app/models/provider/exchange_rate_concept.rb), [security concept](../../app/models/provider/security_concept.rb), and [account syncer](../../app/models/account/syncer.rb) show the current classes and `Balance::Materializer` flow. |
| Lookbook at `/lookbook`; API keys described as JWT tokens | [Routes](../../config/routes.rb) mount Lookbook at `/design-system`; [ApiKey](../../app/models/api_key.rb) generates random hexadecimal keys. |
| SimpleFIN infers pending from a blank posted date | [SimplefinEntry::Processor.pending?](../../app/models/simplefin_entry/processor.rb) requires explicit epoch zero plus a positive transaction timestamp when no explicit pending flag is set. |
| Blanket pending defaults; Lunchflow does not store pending metadata | Initializers for [SimpleFIN](../../config/initializers/simplefin.rb), [Plaid](../../config/initializers/plaid_config.rb), and [Lunchflow](../../config/initializers/lunchflow.rb), the [SimpleFIN importer](../../app/models/simplefin_item/importer.rb), and [Lunchflow processor](../../app/models/lunchflow_entry/processor.rb) distinguish provider defaults, import-layer overrides and stored metadata. |
| Valuations rswag spec still needs OAuth replaced | [valuations_spec.rb](../../spec/requests/api/v1/valuations_spec.rb) already creates an API key and supplies `X-Api-Key`. |
| New migrations must remain Rails 7.2 | [Gemfile](../../Gemfile) requires Rails 8.1; upgrade commit [88343002d](https://github.com/we-promise/sure/commit/88343002d) provides the historical transition. |

No application code or runtime configuration changes are needed to correct these
descriptions. The shared guides link to the implementation for future verification.
