# Feature Gating

Sure already has three layered mechanisms for turning features on and off. Use them. Do not introduce a new framework (no Flipper, no plugin loader, no `app/modules/*/` autoload tree).

## The three gating tiers

| Tier | Where | When to use | Precedent |
|------|-------|-------------|-----------|
| **Instance** | `Rails.application.config.app_mode` (`config/application.rb`) + env vars like `SIMPLEFIN_INCLUDE_PENDING` | Whole-deploy switches: managed vs self-hosted, opt-in integrations that require credentials. | `app_mode.self_hosted?`, `Rails.configuration.x.simplefin.*` |
| **Per-user** | `User#preferences` jsonb | Personal preferences that affect only that user's UI. | `User#preview_features_enabled?` (`app/models/user.rb`), `User#ai_enabled?` |
| **Per-family ("modules")** | `Family#disabled_modules` text[] + `Family#module_enabled?(:name)` | Toggling whole feature verticals (Investments, future: Budgets, Goals, AI). Affects everyone in the family. | `Family#recurring_transactions_disabled?` (existing), `Family#module_enabled?(:investments)` (this doc) |

## The "module" rule

A module is just a string in `families.disabled_modules`. It opts a feature vertical OUT — default is enabled, presence in the array means disabled. Backwards-compatible: existing families ship with `[]` and see no change.

```ruby
family.module_enabled?(:investments) # => true (default)
family.update!(disabled_modules: ["investments"])
family.module_enabled?(:investments) # => false
```

No migrations per module. Add an entry to `Family::AVAILABLE_MODULES` and wire the three enforcement layers below.

## Three enforcement layers — required for every module

The biggest risk with feature gating is **half-enforcement**: hiding the UI but leaving controllers, jobs, or model writes open. A user disables the module, the surface disappears, background jobs keep writing data, and re-enabling produces surprise state. **For every module, all three layers must call `Family#module_enabled?`.**

### 1. View / nav

Inside ERB and helpers, call `module_enabled?(:investments)`. The method is provided as a `helper_method` by `ModuleGateable` (auto-included in `ApplicationController`).

```erb
<% if module_enabled?(:investments) %>
  <%= render "account_type", accountable: Investment.new %>
  <%= render "account_type", accountable: Crypto.new %>
<% end %>
```

For nav items, opt in via the `module:` key in `NavigationHelper#main_nav_items`; disabled modules are filtered out and the bottom-mobile nav redistributes via `justify-around`. **Never auto-fill empty slots** with promoted sidebar items — empty slot is the affordance that the module is off.

### 2. Controller

HTML controllers use the `require_module!` class macro from `ModuleGateable`:

```ruby
class InvestmentsController < ApplicationController
  require_module! :investments
end
```

This redirects to `root_path` with `flash[:alert] = t("modules.not_enabled")` when the module is off.

API controllers (under `Api::V1`) use the instance method on `Api::V1::BaseController`:

```ruby
class Api::V1::HoldingsController < Api::V1::BaseController
  before_action -> { require_module!(:investments) }
end
```

This renders `{ error: "feature_disabled" }` with status `403`. Matches the existing `require_ai_enabled` pattern.

### 3. Background jobs / model writes

If the module has scheduled jobs or model callbacks that write data, guard the entry point:

```ruby
class SomeInvestmentJob < ApplicationJob
  def perform(family_id)
    family = Family.find(family_id)
    return unless family.module_enabled?(:investments)
    # ...
  end
end
```

Without this, toggling off creates silent data accumulation, and toggling back on produces a populated module the user never approved.

## Choosing the right tier

- **Instance**: needs a deploy/restart. Right for integrations bound to env keys (Plaid, SimpleFIN, OpenAI), and for self-hosters who want a feature off at the docker-compose layer.
- **Per-user**: right for opt-in/opt-out personal preferences that don't affect family-shared data (AI sidebar visibility, preview features, dark mode).
- **Per-family module**: right for "we don't want this vertical at all" — affects all family members, the toggle lives in Settings → Preferences, and surfaces across web + API + jobs.

If you find yourself wanting all three for one feature, you probably want per-family with a `Rails.configuration` instance kill-switch. Don't build "the module system" — there isn't one.

## Naming and conventions

- Module names are snake_case strings: `"investments"`, `"goals"`. Plural for verticals, singular for single features.
- Add to `Family::AVAILABLE_MODULES` so the Settings UI picks them up.
- Add locale entries under `modules.<name>.title` and `modules.<name>.description` in `config/locales/views/modules/<locale>.yml`.
- Same string is used in `disabled_modules` array, controller `require_module!` arg, view `module_enabled?` arg, and locale key.

## Not modules

These are foundational primitives. They are not candidates for module gating because too much else FKs into them:

- Account, Transaction, Entry, Trade, Valuation, Balance, Holding, Security
- Category, Merchant, Transfer

If you think one of these should be a module, you are wrong; redesign the feature instead.

## What about a "modules registry"?

Don't build one. Two reasons:

1. You don't have three modules yet, and premature abstraction here is fatal because the surface is forever (per Discourse/WordPress prior art).
2. `Family::AVAILABLE_MODULES` is the registry. It's an array. That's the framework.
