# Gating a beta feature

Sure ships beta features behind a single per-user toggle. Users opt in via Settings → Preferences. Opted-in users see your feature; everyone else doesn't. This guide is for hooking a new feature into the gate.

The intent is to ship in-progress work without blocking smaller PRs on a "feels finished" bar. You gate the entry points (routes, nav, anything that links into your feature) and iterate behind them. Once stable, you remove the gate in a small follow-up PR.

## How the gate works

The state lives on `users.preferences["beta_features_enabled"]`, a key inside the existing JSONB column. It defaults to `false`. Reading it goes through `User#beta_features_enabled?`.

`ApplicationController` includes the `BetaGateable` concern, which exposes two methods to every controller:

- `beta_features_enabled?`. Returns a boolean. `false` for logged-out callers.
- `require_beta_features!`. A `before_action` helper. Redirects non-beta users to `/` with a flash that points them at Settings → Preferences.

The concern also registers `beta_features_enabled?` as a helper method, so views can call it directly.

Key files:

- `app/controllers/concerns/beta_gateable.rb`. The concern.
- `app/models/user.rb`. The `beta_features_enabled?` predicate.
- `app/views/settings/preferences/show.html.erb`. The toggle UI users see.
- `app/components/DS/pill.rb`. The `Beta` / `Canary` marker pill.
- `config/locales/views/beta/en.yml`. The redirect flash copy.

## Gating a controller

Add `require_beta_features!` as a `before_action`. That's it.

```ruby
class GoalsController < ApplicationController
  before_action :require_beta_features!
end
```

Routes stay defined; the gate runs per-request. Non-beta users hitting `/goals` get redirected with a flash. Beta users pass through.

If only some actions are gated, scope the `before_action`:

```ruby
class TransactionsController < ApplicationController
  before_action :require_beta_features!, only: %i[forecast scenarios]
end
```

## Gating a view

Wrap the relevant fragment in the helper:

```erb
<% if beta_features_enabled? %>
  <li>
    <%= link_to t(".nav.goals"), goals_path %>
  </li>
<% end %>
```

Same pattern works for dashboard widgets, scoreboard cards, anything that surfaces beta data alongside non-beta data. The helper resolves on every request and reflects the current user's preference.

## Gating the main nav

The desktop sidebar rail and the mobile bottom nav both render from `app/views/layouts/shared/_nav_item.html.erb`. The partial accepts an optional `beta:` local — when true, it overlays a violet dot-only pill on the icon so opted-in users can tell at a glance that the rail entry leads to a beta surface.

Build the nav-item hash conditionally inside the `beta_features_enabled?` branch and set `beta: true` on it. The compact form using `Array#compact` keeps the array clean:

```erb
<% mobile_nav_items = [
  { name: t(".nav.home"), path: root_path, icon: "pie-chart", icon_custom: false, active: page_active?(root_path) },
  { name: t(".nav.transactions"), path: transactions_path, icon: "credit-card", icon_custom: false, active: page_active?(transactions_path) },
  (beta_features_enabled? ? { name: t(".nav.goals"), path: goals_path, icon: "piggy-bank", icon_custom: false, active: page_active?(goals_path), beta: true } : nil),
  { name: t(".nav.assistant"), path: chats_path, icon: "icon-assistant", icon_custom: true, active: page_active?(chats_path), mobile_only: true }
].compact %>
```

Two things happen from this single change: non-beta users never see the entry (the `nil` gets compacted out) and beta users see the entry with the dot marker (the partial reads `beta:` and renders the pill). You don't need to touch `_nav_item.html.erb` itself.

## Marking the feature in the UI

When a beta surface renders for an opted-in user, mark it. The pill component lives in the design system:

```erb
<%# Next to a page header. The md size pairs with h1 / h2. %>
<%= render DS::Pill.new(label: "Beta", size: :md) %>

<%# Next to a sidebar nav label or section title. sm is the default. %>
<%= render DS::Pill.new(label: "Beta") %>

<%# Same shape, fuchsia tone, for canary / experimental surfaces. %>
<%= render DS::Pill.new(label: "Canary", tone: :fuchsia) %>

<%# Sidebar icon rail has no room for a label. The dot-only mode keeps the tone semantics without the text. %>
<%= render DS::Pill.new(tone: :violet, dot_only: true, title: "Beta") %>
```

Default tone is violet. Tones available: `violet`, `indigo`, `fuchsia`, `amber`, `gray`. Styles: `soft` (default), `filled`, `outline`. Sizes: `sm` (default), `md`. The Lookbook preview at `/design-system` (look for `PillComponentPreview#default`) flips every option, so you can see what your call site renders without a round trip to Rails.

## Tests

Gated controllers should test both states. The pattern:

```ruby
class GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "redirects users without beta access" do
    @user.update!(preferences: (@user.preferences || {}).merge("beta_features_enabled" => false))

    get goals_url

    assert_redirected_to root_path
    assert_match(/beta/i, flash[:alert])
  end

  test "renders for users with beta access" do
    @user.update!(preferences: (@user.preferences || {}).merge("beta_features_enabled" => true))

    get goals_url

    assert_response :success
  end
end
```

If you write a system test, flip the preference in setup the same way before the visit.

## Removing the gate when the feature ships GA

When a feature moves from beta to general availability, removing the gate is a small mechanical PR:

1. Drop the `before_action :require_beta_features!` line from the controller.
2. Unwrap the `if beta_features_enabled?` blocks in views.
3. Drop the `DS::Pill` markers from headers and section titles, and drop the `beta: true` flag from the nav-item hash.
4. Delete the controller / view tests that exercise the redirect.

Grep for `require_beta_features!` and `beta_features_enabled?` near your feature to confirm nothing's left behind.

## Notes

The flag is per-user, not per-family. Two users in the same family can see different versions of the product if one opts in and the other doesn't. That's intentional. Data is family-scoped, but visibility is a personal preference. If you write a feature that creates family-shared data (goals, budgets, etc.), the data persists when a user toggles beta off. The UI just disappears from their view while still showing up for opted-in family members.

The gate does nothing for background jobs. If your feature has a Sidekiq cron job, it runs regardless of who has beta enabled. That's usually correct (data should keep flowing), but if the job sends notifications or emails, gate those at the send site too.

The redirect target is `/`. If you want gated controllers to land somewhere else (a docs page, an opt-in nudge), override `require_beta_features!` in the controller, or write a thin custom `before_action` that calls `beta_features_enabled?` directly.
