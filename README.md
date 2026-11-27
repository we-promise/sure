Multi-part series branch https://github.com/we-promise/sure/tree/refactor/ai-plumbing

---

### Plan

- https://github.com/we-promise/sure/pull/4440 plan documents.

---

### Review order for Milestone 1

Milestone 1 lands as one change: 2c to 2f on this branch plus the #5504 stack, about 500 files. Review it by risk, not by PR.

1. **The plan's decisions.** Every call made by @josh-sanders is a proposal, open to evidence. Scrutinise them first; the code follows from them.
   - [ai-plumbing-redesign.md](https://github.com/josh-sanders/sure/blob/proposal/v0.8-ai-workflow-reviews/docs/proposals/v0.8/ai-plumbing-redesign.md): search for "@josh-sanders". Start with §5.4 (failover and down marks), §18 (breaking changes), §19 (delivery) and §20 (not in scope).
   - The [decisions register](https://github.com/josh-sanders/sure/blob/proposal/v0.8-ai-workflow-reviews/docs/proposals/v0.8/rubyllm-spike-report.md#decisions-register) in the RubyLLM spike report: the evidence for and against each product decision.
   - The per-PR plans in the [same folder](https://github.com/josh-sanders/sure/tree/proposal/v0.8-ai-workflow-reviews/docs/proposals/v0.8) (`pr-2a` to `pr-2f`, `ai-generation-windowing.md`), each with its own decisions.
2. **The upgrade path.** What an existing install meets on deploy:
   - migrations, including dropping `family_documents.account_statement_id`;
   - jobs queued on `main` whose classes are deleted;
   - the old AI ENV and settings read by `Ai::LegacyEnvConfig` (redesign §4.5), including which vector store is chosen;
   - an AI run without family consent fails rather than skipping.
3. **The core.** `Ai::Generation` (§8.1), the transports (§7), the router and down marks (§5), `Ai::Result` and `Ai::Error` (§9), usage and instrumentation (§10).
4. **Each feature through its real entry point.** Bill setup, rule categorization and merchant detection, merchant enhancement, PDF import, document search, Jev, the health probes.
5. **The tests.** `test/architecture` (the invariants, redesign §17) and the recorded evals.

Fixes found in review land as commits on https://github.com/we-promise/sure/pull/5769.

---

### Milestone 1 - December 2026

Merged on this branch:

- https://github.com/we-promise/sure/pull/4773 2a. Transports and instrumentation.
- https://github.com/we-promise/sure/pull/4774 2b. Routing and consent.
- https://github.com/we-promise/sure/pull/4775 2c. Generations.
- https://github.com/we-promise/sure/pull/5209 CI: refuse provider HTTP outside live tests.
- https://github.com/we-promise/sure/pull/4765 2d. Jev and shadow runs.
- https://github.com/we-promise/sure/pull/3422 Bridge the statement vault to search and let tools read a file.
- https://github.com/we-promise/sure/pull/4771 2e. PDF import and document search.
- https://github.com/we-promise/sure/pull/4892 2f. ruby_llm 2.2.3, Jev via OpenRouter, review fixes.

The rest is one stack, https://github.com/we-promise/sure/stack/5504. Each PR targets the one below it and shows only its own changes; merge from the bottom up. Features are frozen: only bugfixes go into these PRs now.

**Merging:** a PR approved by a reviewer (Luis, or anyone who helps) is ready to merge into `refactor/ai-plumbing`. Merge from the bottom, with a merge commit rather than squash or rebase, so the PRs above stay intact. `main` is merged into this branch regularly to keep the final merge small.

1. https://github.com/we-promise/sure/pull/5501 3a. Capsule, shared state and probes off the web thread.
2. https://github.com/we-promise/sure/pull/5502 Tidying 3a and dead code from 2a-2f; review fixes.
3. https://github.com/we-promise/sure/pull/5503 Trimming tests to a few comprehensive AI tests per layer.
4. https://github.com/we-promise/sure/pull/5521 Windowing: fixing 2c's O(N²) runs, a #5077 performance bug.
5. https://github.com/we-promise/sure/pull/5550 2c follow-up: recorded evals that run, set-aside prompt overrides on the family.
6. https://github.com/we-promise/sure/pull/5608 Fix #5077 follow-ups: credentials, rule-run accounting, JSON mode, eval errors. Includes https://github.com/we-promise/sure/pull/5663 (send nullable enums to Anthropic as anyOf), merged into it.
7. https://github.com/we-promise/sure/pull/5769 Fixes before the landing: down-mark lockouts, jobs queued on main.
8. https://github.com/we-promise/sure/pull/5744 Count a mixed rule's ordinary changes as modified.
9. https://github.com/we-promise/sure/pull/5745 Outbox: record each AI job and deliver it again when lost.
10. https://github.com/we-promise/sure/pull/5756 4a. Lanes: a queue per AI lane, and chat threads of its own.
11. https://github.com/we-promise/sure/pull/5758 4b. Gate: one per local model host, with lanes and interrupts.
12. https://github.com/we-promise/sure/pull/5784 4c. Typing hold and visible waiting: chat at the gate, and what it waits for.
13. https://github.com/we-promise/sure/pull/5892 Documents in a job (was #5824).
14. https://github.com/we-promise/sure/pull/5893 Stop a PDF import (was #5825).
15. https://github.com/we-promise/sure/pull/5894 MCP tools in a job (was #5826).
16. https://github.com/we-promise/sure/pull/5895 Bill suggestions and Stop (was #5827).
17. https://github.com/we-promise/sure/pull/5896 Probe suggestion status before catching up a waiting frame (was #5870), with #5857's capsule-only checks merged in.

[Plan for 8-12](https://github.com/josh-sanders/sure/blob/proposal/v0.8-ai-workflow-reviews/docs/proposals/v0.8/stack-sequencer-off-the-web-thread.md). Issue https://github.com/we-promise/sure/issues/5077 tracks follow-up work deferred from these PRs.

Other contributors' PRs on these branches, left to their authors:

- On this branch: https://github.com/we-promise/sure/pull/4425 Propose a transaction split from an attached receipt (draft).
- On #5784: receipt scanning https://github.com/we-promise/sure/pull/5703, web UI https://github.com/we-promise/sure/pull/5794, mobile app https://github.com/we-promise/sure/pull/5795; purchases from forwarded order emails https://github.com/we-promise/sure/pull/5704, web UI https://github.com/we-promise/sure/pull/5796.
- On `main`, parked: https://github.com/we-promise/sure/pull/4844 Run Anthropic AI features on a Claude subscription (draft).

---

### Release notes (draft)

For the release that merges this branch into `main`.

**What this is.** An interim release of the AI plumbing: the new internals (transports, routing and consent, generations, lanes, the local model gate, the outbox) behind the AI configuration you already have. It is not the completed redesign. Settings stored in the database, the AI settings pages, allowed endpoints, own keys and the member switch (redesign PRs 7-9) and the full chat rework (PR 6) come in later releases.

**Configuration is unchanged.** The existing AI environment variables and settings still configure everything; `Ai::LegacyEnvConfig` reads them (redesign §4.5). See [docs/hosting/ai.md](docs/hosting/ai.md).

**Upgrading**

- **Jobs already queued keep running.** `AutoCategorizeJob`, `AutoDetectMerchantsJob`, `EnhanceProviderMerchantsJob` and `WorkerAiHealthCheckJob` stay for one release and hand their work to the new jobs, and the `ai` capsule drains the old `ai_high_priority` and `ai_low_priority` queues for one release. Both go in the release after this one.
- **A custom `sidekiq.yml` needs the new queues** (`ai_interactive`, `ai_prompt`, `ai_background`) and the `ai_chat` capsule; copy the shipped file. A worker started with an old file leaves chats unanswered, and System health says no worker is processing the AI queues.
- **Threads and the database pool.** Each worker that runs AI work gets `RAILS_AI_MAX_THREADS` more threads (default `1`), for chat. They hold a database connection only for each query, so the pool sized by `RAILS_MAX_THREADS` doesn't usually need to grow. `RAILS_MAX_THREADS` must be greater than `RAILS_AI_MAX_THREADS`.
- **`RAILS_AI_MAX_THREADS=0` means that worker runs no AI work at all.** Use it on every worker but one when several share one local model host. At least one worker needs it at `1` or more, or AI jobs wait in their queues and System health reports it.
- **One gate per local model host.** Sure sends a local model host at most as many AI requests at once as it has slots. The gate is keyed by host name, whatever the port, and sized by the server with the fewest slots on that host, so a chat server and an embedding server on one machine share it instead of each filling the GPU.
- **Consent.** An AI run for a family without AI consent now fails, rather than being skipped.
- **Migrations.** 17 new migrations, including moving the statement links on `family_documents` into its metadata and dropping `family_documents.account_statement_id`. Back up before upgrading.
- **Development databases that ran the AI branches before 2026-11-28** need two version fixes, because the branch renumbered migrations: `UPDATE schema_migrations SET version = '20261124120200' WHERE version = '20261124120000';` only if the database ran this branch's statement-link move (a database that only ran `main` needs nothing), and `DELETE FROM schema_migrations WHERE version = '20261126120000';` (those indexes are now created with their table).

**Not in this release** (tracked in #5077): planning each AI job's lane from its plan rather than its queue; the rest of chat and PDF-import cancellation; enforcing capsule-only AI calls in production; probing every route and model in use, and the gate, lane and down-mark diagnostics on the admin page; and the remaining instrumentation (failover and escalation fields, the `llm_usages.operation` backfill).

---

- 6 Chat.

---

- 7 Configuration in the database.

---

- 8 Health and settings pages.

---

- 9 Allowed endpoints, own keys and the member switch.

---


[![Ask DeepWiki](https://img.shields.io/badge/Ask-DeepWiki-blue)](https://deepwiki.com/we-promise/sure)
[![View performance data on Skylight](https://badges.skylight.io/typical/s6PEZSKwcklL.svg)](https://oss.skylight.io/app/applications/s6PEZSKwcklL)
[![Dosu](https://raw.githubusercontent.com/dosu-ai/assets/main/dosu-badge.svg)](https://app.dosu.dev/a72bdcfd-15f5-4edc-bd85-ea0daa6c3adc/ask)
[![Pipelock Security Scan](https://github.com/we-promise/sure/actions/workflows/pipelock.yml/badge.svg)](https://github.com/we-promise/sure/actions/workflows/pipelock.yml)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/we-promise/sure/main/docs/screenshots/dashboard-dark.webp">
  <img alt="The Sure dashboard in two columns (cashflow, net worth, spending and outflows) beside the AI assistant answering a question about savings" src="https://raw.githubusercontent.com/we-promise/sure/main/docs/screenshots/dashboard-light.webp">
</picture>

<p align="center">
  <!-- Keep these links. Translations will automatically update with the README. -->
  <a href="https://readme-i18n.com/de/we-promise/sure">Deutsch</a> | 
  <a href="https://readme-i18n.com/es/we-promise/sure">Español</a> | 
  <a href="https://readme-i18n.com/fr/we-promise/sure">Français</a> | 
  <a href="https://readme-i18n.com/ja/we-promise/sure">日本語</a> | 
  <a href="https://readme-i18n.com/ko/we-promise/sure">한국어</a> | 
  <a href="https://readme-i18n.com/pt/we-promise/sure">Português</a> | 
  <a href="https://readme-i18n.com/ru/we-promise/sure">Русский</a> | 
  <a href="https://readme-i18n.com/zh/we-promise/sure">中文</a>
</p>

# Sure: The personal finance app for everyone

<b>Get
involved: [Discord](https://discord.gg/36ZGBsxYEK) • [Website](https://sure.am) • [Issues](https://github.com/we-promise/sure/issues)</b>

> [!IMPORTANT]
> This repository is a community fork of the now-abandoned Maybe Finance project. <br />
> Learn more in their [final release](https://github.com/maybe-finance/maybe/releases/tag/v0.6.0) doc.

## Backstory

The [Maybe Finance](https://github.com/maybe-finance/maybe) (archived/abandoned repo) team spent most of 2021–2022 building a full-featured personal finance and wealth management app. It even included an “Ask an Advisor” feature that connected users with a real CFP/CFA — all included with your subscription.

The business end of things didn't work out, and so they stopped developing the app in mid-2023.

After spending nearly $1 million on development (employees, contractors, data providers, infra, etc.), the team open-sourced the app. Their goal was to let users self-host it for free — and eventually launch a hosted version for a small fee.

They actually did launch that hosted version … briefly.

That also didn’t work out — at least not as a sustainable B2C business — so now here we are: hosting a community-maintained fork to keep the codebase alive and see where this can go next.

Join us!

## Hosting Sure

Sure is a fully working personal finance app that can be [self hosted with Docker](docs/hosting/docker.md).
Sure can be accessed from a browser, the macOS desktop app, the mobile app, API
clients, and LLM agents. See [Sure Clients](docs/clients.md) for an overview.

## Forking and Attribution

This repo is a community fork of the archived Maybe Finance repo.
You’re free to fork it under the AGPLv3 license — but we’d love it if you stuck around and contributed here instead.

To stay compliant and avoid trademark issues:

- Be sure to include the original [AGPLv3 license](https://github.com/maybe-finance/maybe/blob/main/LICENSE) and clearly state in your README that your fork is based on Maybe Finance but is **not affiliated with or endorsed by** Maybe Finance Inc.
- "Maybe" is a trademark of Maybe Finance Inc. and therefore, use of it is NOT allowed in forked repositories (or the logo)

## Performance Issues

With data-heavy apps, inevitably, there are performance issues. We've set up a public dashboard showing the problematic requests seen on the demo site, along with the stacktraces to help debug them.

[https://www.skylight.io/app/applications/s6PEZSKwcklL/recent/6h/endpoints](https://oss.skylight.io/app/applications/s6PEZSKwcklL/recent/6h/endpoints)

Any contributions that help improve performance are very much welcome.

## Local Development Setup

**If you are trying to _self-host_ the app, [read this guide to get started](docs/hosting/docker.md).**

The instructions below are for developers to get started with contributing to the app.

### Requirements

- See `.ruby-version` file for required Ruby version
- PostgreSQL >9.3 (latest stable version recommended)
- Redis > 5.4 (latest stable version recommended)

### Getting Started
```sh
cd sure
cp .env.local.example .env.local
bin/setup
bin/dev

# Optionally, load demo data
rake demo_data:default
```

Visit http://localhost:3000 to view the app.

If you loaded the optional demo data, log in with these credentials:

- Email: `user@example.com`
- Password: `Password1!`

For further instructions, see guides below.

### Setup Guides

- [Mac dev setup](https://github.com/we-promise/sure/wiki/Mac-Dev-Setup-Guide)
- [Linux dev setup](https://github.com/we-promise/sure/wiki/Linux-Dev-Setup-Guide)
- [Windows dev setup](https://github.com/we-promise/sure/wiki/Windows-Dev-Setup-Guide)
- Dev containers - visit [this guide](https://code.visualstudio.com/docs/devcontainers/containers)

### One-click Install

Render expects each button target branch to have a `render.yaml` at the repository root. The branch-ready Blueprint files live in `branches/<branch-name>/render.yaml` in a separate repo and can be copied to each corresponding branch root.

| Option | What it deploys | `latest` | `stable` |
| --- | --- | --- | --- |
| **Sure - No AI** | Sure web, Sidekiq worker, Render Postgres, and Render Key Value. AI tokens are intentionally blank. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-no-ai) |
| **Sure - Simple AI** | Sure with OpenAI-backed AI settings, pgvector-ready Postgres, Sidekiq, and Render Key Value. Render prompts for the OpenAI token. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-simple-ai) |
| **Sure - External AI** | Sure with external assistant settings plus AlphaClaw, which manages the OpenClaw gateway on Render. | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai-latest) | [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/we-promise/sure-render-templates/tree/sure-external-ai) |

[![Run on PikaPods](https://www.pikapods.com/static/run-button.svg)](https://www.pikapods.com/pods?run=sure)

[![Deploy on Hostim](https://hostim.dev/img/deploy-button.svg)](https://console.hostim.dev/dashboard?preview=1&modal=1&template=sure)

## License and Trademarks

Maybe and Sure are both distributed under
an [AGPLv3 license](https://github.com/we-promise/sure/blob/main/LICENSE).
- "Maybe" is a trademark of Maybe Finance, Inc.
- "Sure" is not, and refers to this community fork.
