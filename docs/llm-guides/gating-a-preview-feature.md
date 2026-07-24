# Gating a preview feature

Sure ships preview features behind a single per-user toggle. Users opt in via Settings → Preferences. Opted-in users see your feature; everyone else doesn't. This guide is for hooking a new feature into the gate.

The intent is to ship in-progress work without blocking smaller PRs on a "feels finished" bar. You gate the entry points (routes, nav, anything that links into your feature) and iterate behind them. Once stable, you remove the gate in a small follow-up PR.

## How the gate works

The state lives on `users.preferences["preview_features_enabled"]`, a key inside the existing JSONB column. It defaults to `false`. Reading it goes through `User#preview_features_enabled?`.

`ApplicationController` includes the `PreviewGateable` concern, which exposes two methods to every controller:

- `preview_features_enabled?`. Returns a boolean. `false` for logged-out callers.
- `require_preview_features!`. A `before_action` helper. Redirects users without preview access to `/` with a flash that points them at Settings → Preferences.

The concern also registers `preview_features_enabled?` as a helper method, so views can call it directly.

Key files:

- `app/controllers/concerns/preview_gateable.rb`. The concern.
- `app/models/user.rb`. The `preview_features_enabled?` predicate.
- `app/views/settings/preferences/show.html.erb`. The toggle UI users see.
- `app/components/DS/pill.rb`. The `Preview` / `Canary` marker pill.
- `config/locales/views/preview/en.yml`. The redirect flash copy.

## Gating a controller

Add `require_preview_features!` as a `before_action`. That's it.

```ruby
class GoalsController < ApplicationController
  before_action :require_preview_features!
end
```

Routes stay defined; the gate runs per-request. Users without preview access hitting `/goals` get redirected with a flash. Preview users pass through.

If only some actions are gated, scope the `before_action`:

```ruby
class TransactionsController < ApplicationController
  before_action :require_preview_features!, only: %i[forecast scenarios]
end
```

## Gating a view

Wrap the relevant fragment in the helper:

```erb
<% if preview_features_enabled? %>
  <li>
    <%= link_to t(".nav.goals"), goals_path %>
  </li>
<% end %>
```

Same pattern works for dashboard widgets, scoreboard cards, anything that surfaces preview data alongside non-preview data. The helper resolves on every request and reflects the current user's preference.

## Gating the main nav

The desktop sidebar rail and the mobile bottom nav both render from `app/views/layouts/shared/_nav_item.html.erb`. The partial accepts an optional `preview:` local — when true, it overlays a violet dot-only pill on the icon so opted-in users can tell at a glance that the rail entry leads to a preview surface.

Use the `preview_gated_nav_item` helper to wrap the entry. It returns `nil` for users without preview access (so the entry never enters the nav, once `Array#compact` runs) and stamps `preview: true` for opted-in users (so the partial paints the dot). One call, both halves of the gate:

```erb
<% mobile_nav_items = [
  { name: t(".nav.home"), path: root_path, icon: "pie-chart", icon_custom: false, active: page_active?(root_path) },
  { name: t(".nav.transactions"), path: transactions_path, icon: "credit-card", icon_custom: false, active: page_active?(transactions_path) },
  preview_gated_nav_item({ name: t(".nav.goals"), path: goals_path, icon: "piggy-bank", icon_custom: false, active: page_active?(goals_path) }),
  { name: t(".nav.assistant"), path: chats_path, icon: "icon-assistant", icon_custom: true, active: page_active?(chats_path), mobile_only: true }
].compact %>
```

You don't need to touch `_nav_item.html.erb` or set `preview: true` by hand. Adding a new preview nav entry is one helper call wrapped around the same hash you'd write anyway.

## Marking the feature in the UI

When a preview surface renders for an opted-in user, mark it. The pill component lives in the design system:

```erb
<%# Next to a page header. The md size pairs with h1 / h2. %>
<%= render DS::Pill.new(label: "Preview", size: :md) %>

<%# Next to a sidebar nav label or section title. sm is the default. %>
<%= render DS::Pill.new(label: "Preview") %>

<%# Same shape, fuchsia tone, for canary / experimental surfaces. %>
<%= render DS::Pill.new(label: "Canary", tone: :fuchsia) %>

<%# Sidebar icon rail has no room for a label. The dot-only mode keeps the tone semantics without the text. %>
<%= render DS::Pill.new(tone: :violet, dot_only: true, title: "Preview") %>
```

Default tone is violet. Tones available: `violet`, `indigo`, `fuchsia`, `amber`, `gray`. Styles: `soft` (default), `filled`, `outline`. Sizes: `sm` (default), `md`. The Lookbook preview at `/design-system` (look for `PillComponentPreview#default`) flips every option, so you can see what your call site renders without a round trip to Rails.

## Tests

Gated controllers should test both states. The pattern:

```ruby
class GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get goals_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders for users with preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get goals_url

    assert_response :success
  end
end
```

If you write a system test, flip the preference in setup the same way before the visit.

## Removing the gate when the feature ships GA

When a feature moves from preview to general availability, removing the gate is a small mechanical PR:

1. Drop the `before_action :require_preview_features!` line from the controller.
2. Unwrap the `if preview_features_enabled?` blocks in views.
3. Drop the `DS::Pill` markers from headers and section titles, and unwrap the `preview_gated_nav_item(...)` call back into a plain nav-item hash.
4. Delete the controller / view tests that exercise the redirect.

Grep for `require_preview_features!` and `preview_features_enabled?` near your feature to confirm nothing's left behind.

## Notes

The flag is per-user, not per-family. Two users in the same family can see different versions of the product if one opts in and the other doesn't. That's intentional. Data is family-scoped, but visibility is a personal preference. If you write a feature that creates family-shared data (goals, budgets, etc.), the data persists when a user toggles preview off. The UI just disappears from their view while still showing up for opted-in family members.

The gate does nothing for background jobs on its own — `PreviewGateable` reads `Current.user`, which a Sidekiq worker doesn't have. A cron job runs regardless of who has preview enabled. That's usually correct: data should keep flowing, so it's there when someone opts in. `SweepExpiredGoalPledgesJob` is the typical shape — it only walks pledges that opted-in users created, so it's naturally inert for everyone else and needs no gate.

Gate the job when it does work that isn't free. Two cases: it sends something outward (notifications, emails — gate at the send site), or it *manufactures* data for every family rather than moving existing data around, burning compute or paid API calls per family. `GenerateInsightsJob` is the second case: seven generators over the income statement and balance sheet, plus optional LLM narration, for every family nightly.

For a family-scoped job, roll the per-user flag up to the family:

```ruby
# app/models/family.rb
scope :with_preview_features, -> { where(id: User.with_preview_features.select(:family_id)) }

def preview_features_enabled?
  users.any?(&:preview_features_enabled?)
end
```

Filter the fan-out with the scope (one indexed query — `User.with_preview_features` is a jsonb containment match against the GIN index on `users.preferences`, not a load-and-iterate), and re-check with the predicate inside the per-family path, which is reachable directly from controllers and the console. Keep the same predicate name on both models so the GA-removal grep finds every call site. `GenerateInsightsJob` is the reference implementation.

One opted-in member is enough to generate for the whole family — consistent with the per-user-visibility / family-scoped-data split described above.

The redirect target is `/`. If you want gated controllers to land somewhere else (a docs page, an opt-in nudge), override `require_preview_features!` in the controller, or write a thin custom `before_action` that calls `preview_features_enabled?` directly.
