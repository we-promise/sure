# Working with the Goals feature

Reference for changes to the savings-goals feature. Covers the data
model, the surfaces that consume it, the load-bearing invariants, and
the gotchas worth knowing before you touch the code.

## Architecture overview

```text
GoalsController#index
  → @active_goals = Family.goals.includes(:open_pledges, linked_accounts: :account_providers)
  → KPI strip + per-goal cards (Goals::CardComponent)
  → pending-pledges callout if any goal has an open pledge

GoalsController#show
  → @goal.open_pledges.reverse_chronological → pending-pledge banners
  → progress ring (Goals::ProgressRingComponent)
  → projection chart (data-controller="goal-projection-chart")
  → Goals::FundingAccountsBreakdownComponent (linked-account rows)
  → Notes section if @goal.notes.present?

GoalPledgesController#create (turbo-frame: modal)
  → goal.goal_pledges.new(amount:, account:, kind: kind_for_account(account))
  → save! → matches?-loop runs once the next sync arrives

Account::ProviderImportAdapter#import_transaction
  → GoalPledge::Reconciler.new(entry).run  (transfer-kind path)
Account::ReconciliationManager#reconcile
  → GoalPledge::Reconciler.new(prepared_valuation).run  (manual_save path)

SweepExpiredGoalPledgesJob (cron, every 15 minutes)
  → GoalPledge.open_and_expired_now.find_each(&:expire!)
```

## Key files

Model layer:

- `app/models/goal.rb` — balance, pace, status, projection, color map.
- `app/models/goal_pledge.rb` — pledge, match policy, lifecycle.
- `app/models/goal_pledge/reconciler.rb` — entry-to-pledge resolver, called from the import adapters.
- `app/models/account.rb` — `#manual?` instance method (mirrors the `Account.manual` scope) drives pledge kind detection.
- `app/models/family.rb` — `#savings_inflow_velocity` powers the KPI strip.

Controllers / routes:

- `app/controllers/goals_controller.rb` — index / show / new / create / edit / update / destroy / pause / resume / complete / archive / unarchive.
- `app/controllers/goal_pledges_controller.rb` — new / create / renew / destroy.
- `config/routes.rb` — `resources :goals do resources :pledges ... member { patch :renew } end`.

Views:

- `app/views/goals/index.html.erb`, `show.html.erb`, `new.html.erb`, `edit.html.erb`.
- `app/views/goals/_form_stepper.html.erb`, `_form_edit.html.erb`, `_pending_pledge_banner.html.erb`, `_empty_state.html.erb`, `_color_picker.html.erb`.
- `app/views/goal_pledges/new.html.erb`.

View components:

- `app/components/goals/card_component.{rb,html.erb}` — goal card on the index.
- `app/components/goals/funding_accounts_breakdown_component.{rb,html.erb}` — per-account widget on show.
- `app/components/goals/avatar_component.{rb,html.erb}` — colored letter/icon avatar.
- `app/components/goals/account_stack_component.{rb,html.erb}` — overlapping account avatars on the card.
- `app/components/goals/progress_ring_component.{rb,html.erb}` — show-page ring.
- `app/components/goals/status_pill_component.{rb,html.erb}` — status chip.

Stimulus controllers:

- `app/javascript/controllers/goal_stepper_controller.js` — two-step create modal.
- `app/javascript/controllers/goal_pledge_preview_controller.js` — live amount-impact preview + helper-text toggle.
- `app/javascript/controllers/goal_projection_chart_controller.js` — D3 projection chart on show.
- `app/javascript/controllers/goals_filter_controller.js` — index filter chips + search, with URL state.

Schema / migrations:

- `db/migrate/20260514120000_create_goal_pledges.rb` — table + enums + partial indexes + amount check.
- `db/migrate/20260514120001_drop_goal_contributions.rb` — old ledger.
- `db/migrate/20260514120002_add_pledge_id_index_to_transactions.rb` — partial unique on `transactions.extra->'goal'->>'pledge_id'`.

Tests / fixtures:

- `test/models/goal_test.rb`, `goal_pledge_test.rb`, `goal_pledge/reconciler_test.rb`.
- `test/controllers/goals_controller_test.rb`, `goal_pledges_controller_test.rb`.
- `test/jobs/sweep_expired_goal_pledges_job_test.rb`.
- `test/fixtures/goals.yml`, `goal_accounts.yml`, `goal_pledges.yml`.

Locales:

- `config/locales/views/goals/en.yml`, `goal_pledges/en.yml`.
- `config/locales/models/goal/en.yml`, `goal_pledge/en.yml`.

## Data model

A goal records a name, target amount, optional target date, color, optional
icon, optional notes, currency, and an AASM `state` (`active` / `paused` /
`completed` / `archived`). It links to depository accounts via the join
table `goal_accounts`.

The goal's *progress* is the live balance of every linked account. There
is no ledger of contributions. `Goal#current_balance` reads
`linked_accounts.sum(:balance)` at request time.

A `GoalPledge` is an intent: amount, account, kind, status, expires_at.
The status enum is `open` / `matched` / `cancelled` / `expired`. The kind
enum is `transfer` / `manual_save`; kind is decided at create time from
the selected account's connection state.

## Status semantics

`Goal#status` is computed at render time:

- `:reached` when `progress_percent >= 100`.
- `:no_target_date` when `target_date.nil?`.
- `:on_track` when the goal has a deadline and `monthly_target_amount <= pace`.
- `:behind` otherwise.

The AASM `state` is independent. Read `Goal#display_status` (not `#status`)
to get the right pill label: it returns the AASM state when it's not
`:active`, otherwise falls through to `#status`.

`Goal#pace` is the rolling 90-day net inflow into the linked accounts,
divided by three. The query joins `entries` with `transactions`
(valuations excluded by join shape), drops excluded entries, and drops
pending provider transactions via `Transaction.excluding_pending`. This
last filter matters: a pending Plaid deposit that later reverses would
otherwise quietly reshape pace.

`Goal#monthly_target_amount` is `(remaining_amount / months_remaining).ceil(2)`.
`months_remaining` uses day precision: `(target_date - Date.current) / 30.0`,
clamped at zero. Calendar-month math is wrong here — it produces a cliff
in the last 30 days where the required monthly rate spikes.

`Goal#catch_up_delta_money` returns `max(0, monthly_target - pace -
sum_of_open_pledges)`. The show-page catch-up alert hides when this is
zero; the pledge CTA inside the alert pre-fills with this delta, so
accepting it once funds the gap rather than stacking the full required
rate on top.

## Pledge match window

`GoalPledge#matches?` checks three things:

1. The pledge is open.
2. The entry is on the pledge's `account_id`.
3. The entry's `date` sits in `[created_at - 5d, max(created_at + 5d, expires_at)]`,
   and the entry's `|amount|` is within `$0.50` or `1%` of the pledge
   amount, whichever is larger.

The upper-bound date widens when `extend!` pushes `expires_at` forward.
Without that widening, "Extend 7 days" would push the expiry forward but
the actual match window would stay anchored at creation.

The reconciler picks pledges by `(account_id, status: "open", kind:
expected_kind, expires_at >= NOW())`. `expected_kind` is `"manual_save"`
for valuation entries and `"transfer"` for transactions.

When a pledge resolves on a transaction, the reconciler stamps
`transaction.extra["goal"]["pledge_id"] = pledge.id` and sets
`pledge.matched_transaction_id`. Two partial unique indexes enforce
single-claim semantics:

- `goal_pledges (matched_transaction_id) WHERE matched_transaction_id IS NOT NULL`
- `transactions ((extra -> 'goal' ->> 'pledge_id')) WHERE (extra -> 'goal' ->> 'pledge_id') IS NOT NULL`

`Goal#last_matched_pledge_at` joins through `matched_transaction_id` to
the entry's `date`, so the show-page header reads the actual entry date,
not `goal_pledges.updated_at`. The distinction matters: a sync resync
would otherwise touch `updated_at` on every matched pledge and reset the
"Last pledge matched N days ago" copy across every goal.

## Connected vs manual accounts

`Account#manual?` returns true when the account has no
`account_providers` association rows, no `plaid_account_id`, and no
`simplefin_account_id`. This mirrors the `Account.manual` query scope.

`Goal#any_connected_account?` returns true when *any* linked account is
not manual. It drives the modal-title copy: connected accounts get
"I just transferred…", manual-only goals get "I just saved…"

`GoalPledgesController#kind_for_account(account)` is per-account:
manual → `manual_save`, connected → `transfer`. A goal with one manual
and one connected linked account works correctly; the kind reflects the
specific account the user picked, not the goal as a whole.

## Color map

`Goal#account_color_map` returns `{ account_id => palette_hex }` for the
goal's linked accounts, sorted by id and assigned palette colors in
order. Three surfaces consume the map: `AccountStackComponent` on the
goal card, the distribution bar in the funding widget, and the avatars
in the funding widget rows. A given account renders the same color on
every surface within a goal.

Account avatars outside a goal context (the new-goal account checklist)
still call `Goals::AvatarComponent.color_for(account.name)`. The
mismatch is acceptable because the form is a one-shot picker, not a
recurring view.

## Common tasks

### Adding a new field to `Goal`

1. Migration: `add_column :goals, :your_field, :type`. Add a partial
   index if the field is queried.
2. Validation: add to `Goal` if presence/range rules apply.
3. Strong params: update `goal_params` and `goal_update_params` in
   `GoalsController`.
4. Form: surface in `app/views/goals/_form_stepper.html.erb` (create) and
   `_form_edit.html.erb` (edit).
5. Locales: add labels under `goals.form_stepper.step1.fields.*` and
   `activerecord.attributes.goal.*`.
6. Display: pick the right surface (header on show, secondary line on
   the card, etc).
7. Tests: extend `test/models/goal_test.rb` for validation; controller
   tests for the form-param flow.

### Adding a new status to `Goal#status`

The enum is implicit in the method body (symbol returns); adding a
state means touching:

1. `Goal#status` to return the new symbol from the right branch.
2. `Goal#display_status` if the new status interacts with the AASM
   states.
3. `Goals::StatusPillComponent::VARIANTS` to add the chip styling
   (classes + icon).
4. `Goals::CardComponent#footer_line` if the footer copy depends.
5. `GoalsController#kpi_payload` if the KPI strip counts it.
6. `config/locales/views/goals/en.yml` under `goals.status.*` for the
   pill label, plus chip and subtitle keys if the new status filters
   on the index.
7. `Goals::StatusPillComponent#status_key` and the goal-filter Stimulus
   controller (`data-status="..."` on chips) if the new status filters.

### Adding a new pledge kind

The kind is a Postgres enum (`goal_pledge_kind`) backing the
`GoalPledge#kind` attribute. Adding a new value:

1. Migration: `ALTER TYPE goal_pledge_kind ADD VALUE 'your_kind'`.
   This is irreversible in Postgres; consider whether you really need a
   new kind versus a different match strategy on an existing one.
2. `GoalPledge::KINDS` constant.
3. `GoalPledgesController#kind_for_account` if the new kind has a
   per-account trigger.
4. `GoalPledge::Reconciler#expected_kind` if the new kind matches a
   different entry shape.
5. Locale + modal helper text in `goal_pledges.new.helper_*`.

### Touching the reconciler

The reconciler is hot — every imported transaction across every provider
calls it. Things to watch:

- The outer `rescue StandardError` is protective: an unexpected raise
  here would break the importer for every account. Keep the rescue, but
  forward to Sentry so the underlying bug stays visible.
- The inner rescue catches `NotOpenError`, `RecordInvalid`, and
  `RecordNotUnique`. These cover the known race conditions (another
  worker claimed the pledge first; another pledge claimed the
  transaction first). Adding new exception classes here should be a
  deliberate decision.
- The `find_each` loop returns from the method on first successful
  resolve. On a rescued failure it falls through to the next candidate
  pledge.

## Gotchas

The same depository account can fund two goals. Both will read the
full balance and double-count progress toward their targets. This is a
known limitation; an allocation primitive that splits the balance
proportionally (or by explicit user weights) would be the way out.

`Goal#pace` includes paychecks, rent, debit-card spend — anything on
the linked account. For a goal linked to primary checking, the metric
matches "net change in balance," not "intentional savings." A user
living paycheck-to-paycheck shows near-zero pace even when they
consciously transfer money in. Isolating intentional savings would need
transfer-pair detection.

Status transitions on a single sub-pace month. The current behaviour is
honest but jarring; a two-month moving condition or a recovery banner
would soften the "great for five months, vacation in June, suddenly
Behind" case.

Light-mode contrast on pale palette entries is weak against
`bg-container`. The fix lives in the design system, not in the goal
feature. The distribution bar segments and the goal-card ring are the
visible surfaces.

`Goal#balance_series_values` rescues `StandardError` and logs to Sentry
when `Balance::ChartSeriesBuilder` raises. The chart degrades to
target-line-only rather than 500ing. If you're debugging "why is the
projection saved-line empty," check Sentry first.

## Demo data

`Demo::Generator#generate_goals!` seeds nine goals chosen to surface
every state on at least one card:

- Active + computed status: `:reached`, `:on_track`, `:behind`,
  `:no_target_date`, plus a past-due active goal that exercises the
  "was due" header copy.
- AASM: paused, archived, completed.
- Two open pledges (banner + index callout).
- One matched pledge bound to a real recent inflow transaction
  (exercises the "Last pledge matched N days ago" header).

Routing goals to different account pools (primary checking holds
the bulk of the balance; secondary checking holds a tenth) is what
forces certain goals to land below their target instead of overshooting.
If you change the demo's account balances, the goal targets need to
move too.

To regenerate from scratch:

```sh
bundle exec rails db:drop db:create db:schema:load
SKIP_CLEAR=1 bundle exec rake demo_data:default
```

`SKIP_CLEAR=0` clears existing data first; on a freshly-loaded schema
the clear step has known issues with the `trades` constraint so the
`SKIP_CLEAR=1` path is the reliable one.

## Background processes

`SweepExpiredGoalPledgesJob` runs every 15 minutes via sidekiq-cron
(`config/schedule.yml`). It scans `GoalPledge.open_and_expired_now` and
flips matching rows to `expired`.

`GoalPledge::Reconciler` runs synchronously inside the existing import
pipeline; it is not a separate job. Any provider sync (Plaid,
SimpleFIN, Lunchflow, Enable Banking, Brex, IBKR, Kraken, SnapTrade) and
any manual balance reconciliation feeds through `Account::ProviderImportAdapter`
or `Account::ReconciliationManager` and trips the reconciler hook.
