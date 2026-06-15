[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/we-promise/sure)
[![View performance data on Skylight](https://badges.skylight.io/typical/s6PEZSKwcklL.svg)](https://oss.skylight.io/app/applications/s6PEZSKwcklL)
[![Dosu](https://raw.githubusercontent.com/dosu-ai/assets/main/dosu-badge.svg)](https://app.dosu.dev/a72bdcfd-15f5-4edc-bd85-ea0daa6c3adc/ask)
[![Pipelock Security Scan](https://github.com/we-promise/sure/actions/workflows/pipelock.yml/badge.svg)](https://github.com/we-promise/sure/actions/workflows/pipelock.yml)

<img width="1270" height="1140" alt="sure_shot" src="https://github.com/user-attachments/assets/9c6e03cc-3490-40ab-9a68-52e042c51293" />

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

## Deployment and Bootstrap Notes

This repository includes an operator-run bootstrap path for setting up the current multi-company owner deployment. The implementation creates the configured company workspaces, provisions the two platform super-admin users plus four family-scoped admin users, and keeps the path idempotent for reruns.

> [!WARNING]
> Do not commit or print bootstrap passwords. Use one-shot environment variables or hidden prompts, and verify dry-runs before making production changes.

| Need | Start here |
| --- | --- |
| Railway deployment shape | [`docs/superpowers/plans/2026-06-10-sure-railway-deployment.md`](docs/superpowers/plans/2026-06-10-sure-railway-deployment.md) |
| Multi-company bootstrap runbook | [`docs/superpowers/plans/2026-06-10-multi-company-bootstrap.md`](docs/superpowers/plans/2026-06-10-multi-company-bootstrap.md) |
| Bootstrap implementation | [`app/services/platform_bootstrap/multi_company_owners.rb`](app/services/platform_bootstrap/multi_company_owners.rb) |
| Bootstrap task | [`lib/tasks/platform_bootstrap.rake`](lib/tasks/platform_bootstrap.rake) |
| Bootstrap test coverage | [`test/services/platform_bootstrap/multi_company_owners_test.rb`](test/services/platform_bootstrap/multi_company_owners_test.rb) |

The production bootstrap task is:

```sh
bin/rails platform_bootstrap:multi_company_owners
```

Set `DRY_RUN=1` to validate the write path without persisting changes.

Bootstrap reruns are intentionally conservative: they do not backfill currency, country, or date-format defaults onto existing families. India defaults (`INR`, `IN`, `%d-%m-%Y`) apply when a family is created for the first time, both through normal signup and through the bootstrap task.

For day-to-day operations, `adminF0@bookeepz.net` and `adminF1@bookeepz.net` use the super-admin bar company picker to enter one of the four family workspaces through an auto-approved impersonation shortcut. The app still uses single-family users under the hood. If a bootstrap family-admin user drifts away from its expected role or family, that picker entry is suppressed and the auto-approved path is disabled until the account is corrected.

Admin-only `Tax`, `Imports`, and `Exports` now live in the main application navigation and render in the primary app shell instead of the Settings shell.

## Browser UAT

Playwright is available as a development dependency for focused browser checks against local or deployed environments.

```sh
npx playwright --version
```

For production UAT, cover at minimum:

- sign-in and sign-out for both platform super-admin users
- dashboard, transactions, reports, budgets, chats, profile, and admin users/SSO pages
- unauthenticated redirects for admin routes
- desktop and mobile viewport checks, with screenshots saved under `tmp/uat-screenshots/`

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

[![Run on PikaPods](https://www.pikapods.com/static/run-button.svg)](https://www.pikapods.com/pods?run=sure)

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/T_draF?referralCode=CW_fPQ)

### Managed OpenClaw for Sure Finances

<a href="https://kilocode.pxf.io/repo-readme"><img src="https://kilo.ai/kiloclaw/partner-resources/kiloclaw-logo-yellow-bg-typography.png" alt="Managed OpenClaw for Sure Finances" width="185"/></a>


## License and Trademarks

Maybe and Sure are both distributed under
an [AGPLv3 license](https://github.com/we-promise/sure/blob/main/LICENSE).
- "Maybe" is a trademark of Maybe Finance, Inc.
- "Sure" is not, and refers to this community fork.

![Alt](https://repobeats.axiom.co/api/embed/3a9753cff07501fba8a6749d0ebd567ff63848c8.svg "Repobeats analytics image")
