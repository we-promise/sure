
<img width="1190" alt="maybe_hero" src="https://github.com/user-attachments/assets/5ed08763-a9ee-42b2-a436-e05038fcf573" />

# ~Maybe~Sure: The personal finance app for everyone

<b>Get
involved: [Discord](https://discord.gg/36ZGBsxYEK) • [Website](https://web.archive.org/web/20250715182050/https://maybefinance.com/) • [Issues](https://github.com/we-promise/sure/issues)</b>

> [!IMPORTANT]
> This repository is a community fork of the official (now abandoned) Maybe Finance one.  
> You can read more about this in their [final release](https://github.com/maybe-finance/maybe/releases/tag/v0.6.0) doc.

## Backstory

The Maybe Finance team spent the better part of 2021/2022 building a personal
finance + wealth management app called "Maybe". Very full-featured, including
an "Ask an Advisor" feature which connected users with an actual CFP/CFA to
help them with their finances (all included in your subscription).

The business end of things didn't work out, and so they shut things down mid-2023.

Having spent the better part of $1,000,000 building the app (employees +
contractors, data providers/services, infrastructure, etc.) they decided to
revive the product as a fully open-source project. The goal was to
let you run the app yourself, for free, and use it to manage your own finances
and eventually offer a hosted version of the app for a small monthly fee.

Which they did.  Offer a hosted version for a short while.

That didn't work either (well, the "making it a sustainable B2C business" part
didn't) so here we are hosting a community maintained fork hoping to keep the
codebase alive and who knows what else will come next.

Join us?

[^^^ STOPPED EDITING HERE ^^^]

## Maybe Hosting

Maybe is a fully working personal finance app that can be [self hosted with Docker](docs/hosting/docker.md).

## Forking and Attribution

This repo is no longer maintained. You’re free to fork it under the AGPLv3. To stay compliant and avoid trademark issues:

- Be sure to include the original [AGPLv3 license](https://github.com/maybe-finance/maybe/blob/main/LICENSE) and clearly state in your README that your fork is based on Maybe Finance but is **not affiliated with or endorsed by** Maybe Finance Inc.
- "Maybe" is a trademark of Maybe Finance Inc. and therefore, use of it is NOT allowed in forked repositories (or the logo)

## Local Development Setup

**If you are trying to _self-host_ the Maybe app, stop here. You
should [read this guide to get started](docs/hosting/docker.md).**

The instructions below are for developers to get started with contributing to the app.

### Requirements

- See `.ruby-version` file for required Ruby version
- PostgreSQL >9.3 (ideally, latest stable version)

After cloning the repo, the basic setup commands are:

```sh
cd maybe
cp .env.local.example .env.local
bin/setup
bin/dev

# Optionally, load demo data
rake demo_data:default
```

And visit http://localhost:3000 to see the app. You can use the following
credentials to log in (generated by DB seed):

- Email: `user@maybe.local`
- Password: `password`

For further instructions, see guides below.

### Setup Guides

- [Mac dev setup guide](https://github.com/maybe-finance/maybe/wiki/Mac-Dev-Setup-Guide)
- [Linux dev setup guide](https://github.com/maybe-finance/maybe/wiki/Linux-Dev-Setup-Guide)
- [Windows dev setup guide](https://github.com/maybe-finance/maybe/wiki/Windows-Dev-Setup-Guide)
- Dev containers - visit [this guide](https://code.visualstudio.com/docs/devcontainers/containers) to learn more

## Copyright & license

Maybe is distributed under
an [AGPLv3 license](https://github.com/maybe-finance/maybe/blob/main/LICENSE). "
Maybe" is a trademark of Maybe Finance, Inc.
