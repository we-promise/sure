# frozen_string_literal: true

# Paycheck Flow Planner (M2): resolves a family's money map for one calendar
# month — which declared income series funds which account at which mode, how
# monthly obligations prorate over that month's ACTUAL paycheck occurrences
# (biweekly months with 2 vs 3 paychecks come out right), where the leftover
# (fun money) lands, and how it is attributed between partners.
#
# Pure Ruby: the instance holds plain data (hashes, Dates, integer-cent
# BigDecimals) and `plan` never touches ActiveRecord. `for_family` is the
# single AR seam — it fetches the inputs at the top and hands them to the
# pure core, so the math is testable with literal hashes.
#
# Money: integer cents (BigDecimal) in the family currency, mirrored from
# RecurringTransaction::PaycheckPlanner#to_family_currency. Rounding happens
# only at the percent edges (half-up to the cent); the leftover edge absorbs
# the remainder, and everything downstream stays exact.
class PaycheckFlowPlanner
  CENTS = 100

  # The single ActiveRecord seam: fetch the month's inputs at the top, then
  # hand the pure core its data.
  #
  # Occurrences are the declared manual income series' scheduled AND paid
  # arrivals inside the month window (paid so past-month views show what
  # actually paid). Obligations are the family's active recurring bills
  # (bill / subscription / installment) paid from the account — the same
  # payable shape PaycheckPlanner funds — monthly-equivalent in family
  # currency. A series' owner is the owner of the account its income lands
  # in (the income table has no owner column of its own).
  def self.for_family(family:, month:)
    new(**inputs_for(family: family, month: month)).plan
  end

  # The `new` kwargs for one month, fetched from AR. Split out of for_family
  # so callers (the flow page's draft preview) can swap :allocations for a
  # shadow set without re-fetching.
  def self.inputs_for(family:, month:)
    window = month.beginning_of_month..month.end_of_month

    occurrences = family.recurring_occurrences
                        .where(status: %w[scheduled paid])
                        .where(due_on: window)
                        .joins(:recurring_transaction)
                        .where(recurring_transactions: { status: :active, bill_type: :income, manual: true })
                        .includes(recurring_transaction: { account: :owner })
                        .order(:due_on)
                        .to_a

    incomes = occurrences.each_with_object({}) do |occurrence, map|
      series = occurrence.recurring_transaction
      entry = map[series.id] ||= {
        id: series.id,
        # Explicit flow label when set, else the landing account's owner.
        owner_id: series.plan_owner_id,
        occurrences: []
      }
      entry[:occurrences] << {
        date: occurrence.due_on,
        amount_cents: to_family_cents(occurrence.resolved_expected_amount_money, family.currency)
      }
    end.values

    debt_accounts = Account.where(family_id: family.id, accountable_type: %w[CreditCard Loan]).select(:id)
    obligations = family.recurring_transactions
                        .where(status: :active, bill_type: %w[bill subscription installment])
                        .where.not(account_id: nil)
                        .merge(
                          RecurringTransaction.where(destination_account_id: nil).or(
                            RecurringTransaction.where(destination_account_id: debt_accounts)
                          )
                        )
                        .to_a
                        .group_by { |series| series.account_id }
                        .transform_values do |series|
                          series.sum { |bill| to_family_cents(bill.monthly_equivalent_amount, family.currency) }
                        end

    {
      month: month,
      incomes: incomes,
      allocations: edge_rows(family),
      obligations_by_account: obligations,
      partners: family.users.order(:created_at, :id).pluck(:id),
      leftover_distribution: family.family_plan_settings&.leftover_distribution || "income_ratio"
    }
  end

  # The family's income -> bank edge rows in the planner's key shape (the
  # draft-able `allocations` set). Shared by inputs_for and the controller's
  # draft merge so the two can never drift.
  def self.edge_rows(family)
    family.income_account_allocations.to_a.map do |allocation|
      {
        income_id: allocation.income_series_id,
        account_id: allocation.account_id,
        mode: allocation.mode,
        value_cents: allocation.mode == "specific" ? allocation.value * CENTS : nil,
        value_percent: allocation.mode == "percent" ? allocation.value : nil
      }
    end
  end

  # Money in the family currency, in integer cents. An unconvertible amount
  # is unknown, and unknown must not be dressed up as zero fun money — but
  # same-currency families (the common case) never hit this. The conversion
  # failure is support-relevant (the amount is unknown downstream), so it
  # lands in the debug log; only the AR seam calls this, never `plan`.
  def self.to_family_cents(money, currency)
    (money.exchange_to(currency).amount * CENTS).round(0, half: :up)
  rescue Money::ConversionError
    DebugLogEntry.capture(
      category: "paycheck_planner",
      level: "warn",
      message: "Unconvertible amount zeroed in PaycheckFlowPlanner#to_family_cents",
      source: "PaycheckFlowPlanner",
      metadata: { source_currency: money.currency.iso_code, target_currency: currency }
    )
    BigDecimal(0)
  end

  # M2 PR#2b (redesign): the planning-diagram entry point. Same pure core +
  # AR-seam shape as for_family, but the inputs also carry the bank -> item
  # allocations, the income link limits, the account roles, and the
  # recommendations the page's "Recommended" list reads.
  #
  # `draft` merges unsaved UI state over the saved inputs (the PR#2 preview
  # pattern): each key present — :allocations (income -> bank edges),
  # :plan_allocations (bank -> item allocations), :plan_max_links,
  # :plan_roles, :incomes — replaces the saved set WHOLESALE. The controller
  # composes the shadow set; the planner never reads the database.
  def self.plan_graph(family:, month:, draft: nil)
    new(**graph_inputs_for(family: family, month: month), draft: draft).plan_graph
  end

  # The `new` kwargs for plan_graph: everything inputs_for fetches (the edge
  # level + PR#1 report), plus the allocation-level inputs.
  def self.graph_inputs_for(family:, month:)
    base = inputs_for(family: family, month: month)

    # Every declared active manual income series — not just the ones with
    # occurrences this month — so the link-limit warnings and the diagram's
    # income nodes show a configured-but-silent paycheck.
    series_by_id = family.recurring_transactions
                         .where(status: :active, bill_type: "income", manual: true)
                         .index_by(&:id)
    enriched = base[:incomes].map do |income|
      series = series_by_id[income[:id]]
      income.merge(name: series ? series.display_name : nil)
    end
    missing = series_by_id.keys - base[:incomes].map { |income| income[:id] }
    incomes = enriched + missing.map do |id|
      {
        id: id,
        name: series_by_id[id].display_name,
        owner_id: series_by_id[id].plan_owner_id,
        occurrences: []
      }
    end

    base.merge(
      incomes: incomes,
      currency: family.currency,
      **graph_shadow(family),
      recommendations: recommendation_rows(family)
    )
  end

  # The raw shadow set of the draft-able inputs — the same rows the planner
  # receives from the AR seam. A controller merges the form's draft rows over
  # this set and hands the whole thing back as `draft:` (the planner applies
  # each present key wholesale), so a preview never re-queries per row.
  def self.graph_shadow(family)
    {
      plan_allocations: plan_allocation_rows(family),
      required_amounts: required_amount_rows(family),
      plan_max_links: family.recurring_transactions
                            .where(status: :active, bill_type: "income")
                            .where.not(plan_max_account_links: nil)
                            .pluck(:id, :plan_max_account_links)
                            .to_h,
      plan_roles: family.accounts.where.not(plan_role: nil).pluck(:id, :plan_role).to_h,
      auto_transfers: family.accounts
                       .where.not(auto_transfer_to_account_id: nil)
                       .pluck(:id, :auto_transfer_to_account_id)
                       .to_h,
      # Round 11 issue 8: the sub-account links (child => parent) and the
      # ordered auto-transfer fan-out targets (parent => [child_ids]). The
      # array order is the diagram's band order, so the raw column flows
      # through untouched; empty arrays are dropped (no fan-out declared).
      sub_account_links: family.accounts
                          .where.not(parent_account_id: nil)
                          .pluck(:id, :parent_account_id)
                          .to_h,
      auto_transfer_targets: family.accounts
                              .pluck(:id, :auto_transfer_target_ids)
                              .reject { |_id, targets| Array(targets).empty? }
                              .to_h,
      # Round 11 issue 8: bank display names (the over-plan line names the
      # unsatisfied bucket; the sankey labels themselves come from page
      # state, so this is payload-side only).
      account_names: family.accounts.pluck(:id, :name).to_h,
      # Round 16 (owner note 4): the plaintext last-4 of each bank from
      # plaid_accounts.mask via account_providers (accounts.plaid_account_id
      # is NULL everywhere in dev; the live link is account_providers with
      # provider_type "PlaidAccount"). Blank masks emit nil — the payload
      # NEVER carries fabricated digits.
      account_last4s: account_last4s_for(family),
      # Round 16 (owner note 3b): the explicit per-account logo slugs
      # (accounts.bank_logo_slug, set from the bank config dialog's picker)
      # plus the pure input maps for keyword auto-match + the vendored set.
      # Resolution happens in build_graph_report (explicit -> keyword -> nil)
      # so the pure-core tests cover the order.
      account_bank_logos: family.accounts
                            .where.not(bank_logo_slug: nil)
                            .pluck(:id, :bank_logo_slug)
                            .to_h,
      bank_logo_keywords: BankLogoSlugs.keywords,
      bank_logos: BankLogoSlugs.available,
      # Round 16 (owner note 2): category id => { name, color } so the
      # allocation rows can carry the Sure category's color.
      categories: family.categories.pluck(:id, :name, :color)
                             .to_h { |id, name, color| [ id, { name: name, color: color } ] },
      plan_ordered: family.accounts
                        .where.not(plan_order: nil)
                        .order(:plan_order)
                        .pluck(:id, :plan_order)
                        .to_h,
      linked_bank_counts: family.income_account_allocations.group(:income_series_id).count
    }
  end

  def self.plan_allocation_rows(family)
    family.plan_allocations.order(:sort_index, :name, :id).to_a.map do |allocation|
      {
        id: allocation.id,
        account_id: allocation.account_id,
        name: allocation.name,
        kind: allocation.kind,
        mode: allocation.mode,
        value_cents: allocation.value_cents,
        value_percent: allocation.value_percent,
        cadence: allocation.cadence,
        recurring_transaction_id: allocation.recurring_transaction_id,
        auto_transfer: allocation.auto_transfer,
        # Round 16: the Sure category the diagram colors the band with.
        # nil = no category (the row carries category_name/color nil too).
        category_id: allocation.category_id
      }
    end
  end

  # Round 16 (owner note 4): { account_id => mask-or-nil } from the
  # plaintext plaid_accounts.mask column, joined through account_providers
  # (the legacy accounts.plaid_account_id FK is NULL everywhere in dev).
  # Two small queries; blank masks become nil — never a fabricated digit.
  def self.account_last4s_for(family)
    rows = family.accounts
                   .joins(:account_providers)
                   .where(account_providers: { provider_type: "PlaidAccount" })
                   .pluck(:id, "account_providers.provider_id")
    return {} if rows.empty?

    masks = PlaidAccount.where(id: rows.map(&:last).uniq)
                           .pluck(:id, :mask)
                           .to_h
    rows.each_with_object({}) do |(account_id, provider_id), result|
      result[account_id] = masks[provider_id].presence
    end
  end

  # Required-mode allocations with no explicit value resolve their amount
  # from the linked transaction's monthly equivalent (AR seam; the pure core
  # receives the map).
  def self.required_amount_rows(family)
    ids = family.plan_allocations
                .where(mode: "required", value_cents: nil)
                .where.not(recurring_transaction_id: nil)
                .pluck(:recurring_transaction_id)
                .uniq
    return {} if ids.empty?

    family.recurring_transactions
         .where(id: ids)
         .to_a
         .to_h { |series| [ series.id, to_family_cents(series.monthly_equivalent_amount, family.currency) ] }
  end

  # The "Recommended" rows the page's autofill reads (spec section 4, query
  # part). Plain hashes — the planner stays AR-free.
  def self.recommendation_rows(family)
    rows = []

    # (a) Detected bills not yet covered by any allocation: an active bill /
    # subscription / installment with a paying account that no allocation
    # references. Autofill: name, cadence from the interval rules, amount =
    # monthly equivalent, source bank = the bill's own account.
    covered = family.plan_allocations.where.not(recurring_transaction_id: nil).pluck(:recurring_transaction_id).to_set
    family.recurring_transactions
         .where(status: :active, bill_type: %w[bill subscription installment])
         .where.not(account_id: nil)
         .where.not(id: covered)
         .order(:name, :id)
         .each do |series|
      rows << {
        type: "recurring_transaction",
        recurring_transaction_id: series.id,
        name: series.display_name,
        kind: series.typed_installment? ? "debt" : "bill",
        cadence: cadence_for(series),
        amount_cents: to_family_cents(series.monthly_equivalent_amount, family.currency),
        source_account_id: series.account_id
      }
    end

    # (b) Accounts labeled with a plan role that have no allocation yet —
    # the "bank as allocation" case (round 20: any of the five roles). Debt
    # roles (CC / loan payoff) autofill a "Pay off <name>" debt row; the
    # rest (savings bucket / checking / investment) are money destinations
    # and autofill a plain savings-style row. The frozen allocation schema
    # carries no target-account column, so "already planned" = an allocation
    # sourced from the account OR named after it (the autofill name, below);
    # source bank stays a user choice.
    alloc_names = family.plan_allocations.pluck(:name).map { |name| name.to_s.strip.downcase }.to_set
    family.accounts.visible.where.not(plan_role: nil).order(:name, :id).each do |account|
      next if family.plan_allocations.exists?(account_id: account.id)
      next if alloc_names.include?(account.name.to_s.strip.downcase)

      rows << {
        type: "account",
        account_id: account.id,
        name: role_allocation_name(account),
        kind: Account.plan_role_debt?(account.plan_role) ? "debt" : "savings",
        cadence: nil,
        amount_cents: nil,
        source_account_id: nil
      }
    end

    # (c) Budget categories with no matching allocation — an envelope that
    # plans money but the diagram does not fund (e.g. "Pet Savings"). Match
    # is by name, case-insensitive, against the allocations' names (the
    # savings-style categories have no recurring transaction to link).
    budget = family.budgets.where.not(budgeted_spending: nil).order(start_date: :desc).first
    if budget
      family.plan_allocations.pluck(:name).map { |name| name.to_s.strip.downcase }.to_set.tap do |names|
        budget.budget_categories
             .joins(:category)
             .where(categories: { parent_id: nil })
             .where("budgeted_spending > 0")
             .order("categories.name")
             .each do |budget_category|
          category_name = budget_category.category.name.to_s.strip.downcase
          next if names.include?(category_name)

          rows << {
            type: "budget_category",
            category_id: budget_category.category_id,
            name: budget_category.category.name,
            kind: "savings",
            cadence: nil,
            amount_cents: nil,
            source_account_id: nil
          }
        end
      end
    end

    rows
  end

  # The allocation the (b) autofill proposes for a role account. Round 20:
  # debt roles keep the "Pay off <name>" label; the other roles
  # (savings bucket / checking / investment) are destinations, not payoffs.
  def self.role_allocation_name(account)
    Account.plan_role_debt?(account.plan_role) ? "Pay off #{account.name}" : account.name
  end

  # Cadence label from the recurrence interval rules (the allocation dialog
  # autofill). 0 rules = the legacy monthly bill. Mixed rules do not map to
  # one of the five labels, so nil (the dialog shows a blank, editable
  # field).
  def self.cadence_for(series)
    rules = series.recurrence_rules.reject(&:marked_for_destruction?)
    # Zero rules is legal: legacy "monthly on expected_day_of_month".
    return "monthly" if rules.empty?

    signatures = rules.map { |rule| [ rule.frequency, rule.interval ] }
    return nil unless signatures.uniq.size == 1

    frequency, interval = signatures.first
    case frequency
    when "weekly"  then interval == 1 ? "weekly" : (interval == 2 ? "biweekly" : nil)
    when "monthly" then interval == 1 ? "monthly" : (interval == 3 ? "quarterly" : nil)
    when "yearly"  then interval == 1 ? "yearly" : nil
    else nil
    end
  end

  # `incomes` is { id:, owner_id:, occurrences: [{ date:, amount_cents: }] }
  # (occurrences = the actual paycheck dates landing in the month), `allocations`
  # is [{ income_id:, account_id:, mode:, value_cents: (specific),
  # value_percent: (percent) }], `obligations_by_account` is { account_id =>
  # monthly BigDecimal cents }, `partners` the family member ids, and
  # `leftover_distribution` the family's attribution setting.
  # The PR#2b inputs are all optional keyword defaults so the PR#1
  # constructor shape (and its tests) keep working unchanged; `plan` ignores
  # them.
  def initialize(month:, incomes:, allocations:, obligations_by_account:, partners:, leftover_distribution:,
                 currency: nil, plan_allocations: [], required_amounts: {}, plan_max_links: {},
                 plan_roles: {}, auto_transfers: {}, plan_ordered: {}, linked_bank_counts: {},
                 recommendations: [], sub_account_links: {}, auto_transfer_targets: {},
                 account_names: {}, account_last4s: {}, account_bank_logos: {},
                 bank_logo_keywords: [], bank_logos: {}, categories: {}, draft: nil)
    @month = month
    @incomes = incomes
    @allocations = allocations
    @obligations_by_account = obligations_by_account
    @partners = partners
    @leftover_distribution = leftover_distribution
    @currency = currency
    @plan_allocations = plan_allocations
    @required_amounts = required_amounts
    @plan_max_links = plan_max_links
    @plan_roles = plan_roles
    @auto_transfers = auto_transfers
    @plan_ordered = plan_ordered
    @linked_bank_counts = linked_bank_counts
    @recommendations = recommendations
    # Round 11 issue 8: sub-account links {child_id => parent_id} and the
    # ordered auto-transfer fan-out targets {parent_id => [child_ids]} (the
    # array order IS the diagram's band order). plan_graph only — the PR#1
    # plan() path never reads them (inputs_for carries no such keys).
    @sub_account_links = sub_account_links
    @auto_transfer_targets = auto_transfer_targets
    # Bank display names {id => name}: the bank rows are id-keyed like every
    # other row, and the over-plan line names the unsatisfied bucket by its
    # ACCOUNT name (the sankey itself pulls labels from page-load state).
    @account_names = account_names
    # Round 16: last-4 {id => mask-or-nil}, explicit logo slugs {id => slug},
    # keyword pairs [normalized_keyword, slug] (longest first), the vendored
    # {slug => label} set, and category id => { name, color }. All optional;
    # plan_graph emits nil where a row has no value (no fabricated data).
    @account_last4s = account_last4s
    @account_bank_logos = account_bank_logos
    @bank_logo_keywords = bank_logo_keywords
    @bank_logos = bank_logos
    @categories = categories
    apply_draft(draft) if draft
  end

  # Draft merge (PR#2 preview pattern): each key present replaces the saved
  # input set WHOLESALE. The controller composes the shadow set (saved rows
  # overlaid with the unsaved dialog rows); the planner just applies it.
  def apply_draft(draft)
    @incomes = draft[:incomes] if draft.key?(:incomes)
    @allocations = draft[:allocations] if draft.key?(:allocations)
    @plan_allocations = draft[:plan_allocations] if draft.key?(:plan_allocations)
    @plan_max_links = draft[:plan_max_links] if draft.key?(:plan_max_links)
    @plan_roles = draft[:plan_roles] if draft.key?(:plan_roles)
  end

  def plan
    paycheck_events = @incomes.flat_map { |income| income[:occurrences] }
    total_occurrences = paycheck_events.size

    # Monthly obligations prorated over the month's actual occurrences. With
    # no paychecks there is nothing to spread across, so the per-paycheck
    # figure stays the monthly total (it is never applied — no paychecks).
    divisor = [ total_occurrences, 1 ].max
    required_per_paycheck = @obligations_by_account
                            .transform_values { |monthly| monthly / divisor }

    resolve_edges(required_per_paycheck:)

    # Per-paycheck (per date) view: what each paycheck resolves to, per edge
    # and per account.
    by_date = Hash.new { |h, k| h[k] = { total: BigDecimal(0), by_account: {} } }
    @resolved.each do |(income_id, date), entry|
      bucket = by_date[date]
      bucket[:total] += entry[:amount]
      entry[:amounts].each { |account_id, amount| bucket[:by_account][account_id] = (bucket[:by_account][account_id] || BigDecimal(0)) + amount }
      # The remainder lands in the leftover edge's account so the per-account
      # totals reconcile exactly against the paycheck total.
      leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
      if leftover_edge
        account_id = leftover_edge[:account_id]
        bucket[:by_account][account_id] = (bucket[:by_account][account_id] || BigDecimal(0)) + entry[:leftover]
      end
    end

    attribution = compute_attribution

    # Shortfalls: occurrences where the pre-leftover edges outran the income.
    shortfalls = {}
    @resolved.each do |(income_id, _date), entry|
      next if entry[:leftover].zero? || entry[:leftover].positive?

      shortfalls[income_id] = (shortfalls[income_id] || BigDecimal(0)) + entry[:leftover].abs
    end

    build_report(
      by_date: by_date,
      required_per_paycheck: required_per_paycheck,
      total_occurrences: total_occurrences,
      pool_month: attribution[:pool_month],
      weights: attribution[:weights],
      deltas: attribution[:deltas],
      target: attribution[:target],
      spread: attribution[:spread],
      fix: attribution[:fix],
      shortfalls: shortfalls,
      partner_actual_month: attribution[:partner_actual_month]
    )
  end

  # M2 PR#2b (redesign): the planning diagram. Incomes -> banks -> items,
  # with the fixed bank-level resolution order:
  #   1. REQUIRED items (bills/debts, mode required) — always first, and
  #      NEVER the over-plan flag target;
  #   2. SPECIFIC items — the per-paycheck hard number;
  #   3. PERCENT items — a share of the bank's leftover pool (the residual
  #      after 1-2);
  #   4. LEFTOVER items — split the final residual equally.
  #
  # The income -> bank edge level resolves EXACTLY like `plan` (the Sankey
  # bands), but a bank's required base is its required plan allocations
  # (explicit monthly value_cents, else the linked transaction's monthly
  # equivalent — see graph_required_monthly) when it has any, falling back
  # to the legacy raw-bill obligations (the pre-redesign behavior, which is
  # this same call with an empty allocation set).
  #
  # Money: integer cents internally; every *_cents field in the JSON is a
  # 2-dp major-unit display string (house convention, same as the PR#1
  # report's money() fields).
  def plan_graph
    total_occurrences = @incomes.sum { |income| income[:occurrences].size }
    divisor = [ total_occurrences, 1 ].max

    # Edge level (income -> bank): a bank's required base is reserved from
    # the paychecks that FUND the bank -- the occurrences of the incomes
    # with a required edge to it -- not from the month's total paycheck
    # count. The global divisor (the pre-fix behavior) split a bank's base
    # across payees whose paychecks never reach the bank, so a bank fed by
    # one partner's two paychecks received a quarter of its bills' base and
    # its allocations ran structurally short (owner round 10, issue 1: the
    # /8 artifact). No required edge into a bank means no reservation: the
    # base never flows, and the bank-level fallback shows the full
    # shortfall (see resolve_graph).
    required_monthly = graph_required_monthly
    edge_funding = required_edge_funding_counts
    required_per_paycheck = required_monthly.each_with_object({}) do |(account_id, monthly), per_paycheck|
      funding = edge_funding.fetch(account_id, 0)
      per_paycheck[account_id] = funding.positive? ? monthly / funding : BigDecimal(0)
    end

    resolve_edges(required_per_paycheck:)
    attribution = compute_attribution
    # Unassigned allocations (owner review round 3, R3: a bank was removed
    # from the plan, the allocation persisted without a source bank) take no
    # part in resolution -- they are reported in the graph with status
    # "unassigned" (see build_graph_report) and never become a bank key.
    allocations_by_bank = @plan_allocations.reject { |allocation| allocation[:account_id].nil? }
                                           .group_by { |allocation| allocation[:account_id] }
    graph = resolve_graph(allocations_by_bank: allocations_by_bank, divisor: divisor)

    build_graph_report(
      graph: graph,
      allocations_by_bank: allocations_by_bank,
      divisor: divisor,
      total_occurrences: total_occurrences,
      fix: attribution[:fix]
    )
  end

  private

    # Edge-level resolution shared by `plan` and `plan_graph`: every
    # occurrence, edge-by-edge, priority required -> specific -> percent ->
    # leftover. The required amount is the caller's per-paycheck figure for
    # the account: `plan` derives it as monthly over the month's total
    # occurrences (the PR#1 behavior); `plan_graph` derives it as monthly
    # over the paychecks that fund the account (see
    # required_edge_funding_counts), so summing the figure over the account's
    # funding paychecks lands on its monthly required base. Sets @resolved,
    # keyed [income_id, date].
    def resolve_edges(required_per_paycheck:)
      resolved = {}
      @incomes.each do |income|
        edges = @allocations.select { |edge| edge[:income_id] == income[:id] }
        income[:occurrences].each do |occurrence|
          key = [ income[:id], occurrence[:date] ]
          amounts = {}
          spent = BigDecimal(0)
          edges.each do |edge|
            case edge[:mode]
            when "required"
              amounts[edge[:account_id]] = required_per_paycheck.fetch(edge[:account_id], BigDecimal(0))
              spent += amounts[edge[:account_id]]
            when "specific"
              amounts[edge[:account_id]] = edge[:value_cents]
              spent += edge[:value_cents]
            when "percent"
              # Round to the cent; the remainder deliberately lands in leftover.
              amount = (occurrence[:amount_cents] * edge[:value_percent]).round(0, half: :up)
              amounts[edge[:account_id]] = amount
              spent += amount
              # leftover is computed below
            end
          end
          leftover = occurrence[:amount_cents] - spent

          resolved[key] = {
            amounts: amounts,
            leftover: leftover,
            edges: edges,
            amount: occurrence[:amount_cents],
            owner_id: income[:owner_id]
          }
        end
      end
      @resolved = resolved
    end

    # Per-partner leftover attribution, shared by `plan` and `plan_graph`:
    # the pooled leftover, the weights, the per-partner deltas against the
    # even target, and the closed-form suggested fix.
    def compute_attribution
      # Leftover pool: only what actually lands in a leftover edge, signed.
      # Negative means obligations outran income (shortfall).
      pool_by_income = {}  # income_id => month leftover across occurrences (streams with a leftover edge)
      @incomes.each do |income|
        next unless income[:occurrences].any?
        next unless @allocations.any? { |edge| edge[:income_id] == income[:id] && edge[:mode] == "leftover" }

        pool_by_income[income[:id]] =
          income[:occurrences].sum { |occ| @resolved[[ income[:id], occ[:date] ]][:leftover] }
      end
      pool_month = pool_by_income.values.sum

      # Per-partner attribution of the pooled leftover.
      partner_income_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @incomes.each do |income|
        next unless income[:owner_id]

        partner_income_month[income[:owner_id]] += income[:occurrences].sum { |occ| occ[:amount_cents] }
      end
      total_attributed_income = partner_income_month.values.sum

      n = @partners.size
      weights = {}
      @partners.each do |partner|
        case @leftover_distribution
        when "equal_split", "custom" # custom rules are v2; attribute evenly until they land
          weights[partner] = BigDecimal(1) / n if n.positive?
        else # income_ratio
          share = partner_income_month[partner]
          weights[partner] = if n.positive? && total_attributed_income.positive?
            share / total_attributed_income
          else BigDecimal(1) / n
          end if n.positive?
        end
      end

      # Per-partner ACTUAL leftover (their own streams' remainders, with or
      # without a leftover edge) is what the delta and the suggested fix work
      # on: attribution credits pooled money, the gap shows whose money is
      # actually left unassigned.
      partner_actual_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @incomes.each do |income|
        next unless income[:owner_id]

        partner_actual_month[income[:owner_id]] +=
          income[:occurrences].sum { |occ| @resolved[[ income[:id], occ[:date] ]][:leftover] }
      end
      actual_total = partner_actual_month.values.sum
      target = n.positive? ? actual_total / n : BigDecimal(0)
      deltas = @partners.to_h { |partner| [ partner, partner_actual_month[partner] - target ] }
      spread = deltas.values.max - deltas.values.min if deltas.any?

      # Suggested fix: closed-form one-variable solve. Shift the single
      # percent edge of the partner furthest above target so their leftover
      # lands on target. Shifting a stream's fraction by d moves its monthly
      # leftover by d * (stream month total), so d = delta / stream month
      # total.
      fix = suggested_fix(deltas, partner_actual_month)

      {
        pool_month: pool_month,
        weights: weights,
        deltas: deltas,
        target: target,
        spread: spread,
        fix: fix,
        partner_actual_month: partner_actual_month
      }
    end

    # ======================================================================
    # plan_graph (M2 PR#2b) helpers
    # ======================================================================

    # The bank -> item resolution for every paycheck date. Returns:
    #   :dates                - sorted paycheck dates with any inflow
    #   :bands                - [{ income_id:, account_id:, date:, amount:, mode: }]
    #                            (income -> bank Sankey bands; signed)
    #   :unallocated          - [{ income_id:, date:, amount: }] (the hatched
    #                            "Un-Allocated" bands; 0 when a leftover edge
    #                            routes the remainder)
    #   :bank_inflow          - { date => { account_id => signed inflow } }
    #   :bank_surplus         - { date => { account_id => signed residual } }
    #   :allocation_results   - { date => { account_id => { allocation_id =>
    #                            { wanted:, got:, shortfall: } } } }
    #   :over_plans           - { income_id => { target:, target_id:, shortfall: } }
    #
    # Statuses: ok (fully funded), partly (0 < got < wanted; bills/debts cap
    # here — they are never the over-plan flag target), over (got == 0 <
    # wanted, savings/fun_money only).
    def resolve_graph(allocations_by_bank:, divisor:)
      dates = @incomes.flat_map { |income| income[:occurrences].map { |occ| occ[:date] } }.uniq

      # The paychecks that fund each bank at the allocation level: the dates
      # on which any resolved income -> bank edge (any mode) fires for the
      # bank. An allocation's MONTHLY figure prorates over its source
      # bank's paychecks -- not the month's total paycheck count, which
      # spans payees whose paychecks never reach the bank (owner round 10,
      # issue 1: the /N artifact). Banks with no funding dates (no edges
      # into them) keep the legacy global shape: entries on every paycheck
      # date, got 0, so the UI still shows the full monthly shortfall.
      bank_funding_dates = {}
      @incomes.each do |income|
        next unless income[:occurrences].any?

        income_edges = @allocations.select { |edge| edge[:income_id] == income[:id] }
        next if income_edges.empty?

        income[:occurrences].each do |occurrence|
          income_edges.each do |edge|
            (bank_funding_dates[edge[:account_id]] ||= []) << occurrence[:date]
          end
        end
      end
      bank_funding_dates = bank_funding_dates.transform_values { |days| days.uniq }

      bands = []
      unallocated = []
      bank_inflow = Hash.new { |h, k| h[k] = {} }
      bank_surplus = {}
      allocation_results = {}

      # Per-paycheck, per-bank demand for the over-plan formula (required
      # wanted is the FULL prorated figure, not what the bank actually had —
      # the flag measures the gap between what the plan demands and what the
      # income provides).
      demand_by_bank = {}  # date => { account_id => BigDecimal }
      fun_targets_by_bank = {}  # date => { account_id => allocation_id }
      dates.each do |date|
        demand_by_bank[date] = {}
        fun_targets_by_bank[date] = {}
        (allocations_by_bank.keys).each do |bank_id|
          allocs = allocations_by_bank[bank_id]
          next if allocs.empty?

          funding = bank_funding_dates.fetch(bank_id, [])
          scale = if funding.empty?
            # Unfunded bank: the legacy global proration keeps the
            # gap visible on every paycheck date.
            divisor
          else
            next unless funding.include?(date)
            funding.size
          end

          bills = allocs.select { |a| a[:mode] == "required" }.sum { |a| allocation_monthly(a) }
          fixed = allocs.select { |a| a[:mode] == "specific" }.sum { |a| a[:value_cents] || BigDecimal(0) }
          # percent demand is a share of the post-bill pool; computed per
          # date below once the bank's inflow is known.
          demand_by_bank[date][bank_id] = bills / scale + fixed
          fun_targets_by_bank[date][bank_id] = allocs.find { |a| a[:kind] == "fun_money" }&.dig(:id)
        end
      end

      dates.each do |date|
        # Inflow per bank from the resolved income -> bank edges (the
        # leftover edge's signed remainder included).
        inflow = {}
        @incomes.each do |income|
          occurrence = income[:occurrences].find { |occ| occ[:date] == date }
          next unless occurrence

          entry = @resolved[[ income[:id], date ]]
          entry[:amounts].each do |account_id, amount|
            inflow[account_id] = (inflow[account_id] || BigDecimal(0)) + amount
            bands << { income_id: income[:id], account_id: account_id, date: date, amount: amount, mode: entry[:edges].find { |e| e[:account_id] == account_id }&.dig(:mode) }
          end
          leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
          if leftover_edge
            account_id = leftover_edge[:account_id]
            inflow[account_id] = (inflow[account_id] || BigDecimal(0)) + entry[:leftover]
            bands << { income_id: income[:id], account_id: account_id, date: date, amount: entry[:leftover], mode: "leftover" }
          else
            # No leftover edge: the remainder never flows to a bank.
            unallocated << { income_id: income[:id], date: date, amount: [ entry[:leftover], BigDecimal(0) ].max }
          end
        end
        bank_inflow[date] = inflow

        # Percent demand: a share of the bank's post-bill pool.
        allocations_by_bank.each do |bank_id, allocs|
          next if inflow[bank_id].nil? || inflow[bank_id] <= 0
          next unless allocs.any? { |a| a[:mode] == "percent" }

          # Positive inflow implies an edge fired this date, so the bank is
          # funded and this is one of its funding dates (empty only
          # defensively).
          funding = bank_funding_dates.fetch(bank_id, [])
          bills = allocs.select { |a| a[:mode] == "required" }.sum { |a| allocation_monthly(a) } /
            (funding.empty? ? divisor : funding.size)
          pool = inflow[bank_id] - bills
          percent_wanted = pool.positive? ? allocs.select { |a| a[:mode] == "percent" }
                                        .sum { |a| (pool * a[:value_percent]).round(0, half: :up) }
                                          : BigDecimal(0)
          demand_by_bank[date][bank_id] += percent_wanted
        end

        # Bank-level allocation resolution, fixed order. An allocation's
        # monthly figure prorates over its source bank's paychecks (the
        # dates with an edge into the bank); banks with planned allocations
        # but no edges in still resolve (remaining 0) on every paycheck
        # date, so their wanted figures are recorded and the UI can show
        # the shortfall.
        (inflow.keys | allocations_by_bank.keys).each do |bank_id|
          allocs = allocations_by_bank[bank_id] || []
          funding = bank_funding_dates.fetch(bank_id, [])
          # A funded bank resolves only on its funding dates: its monthly
          # figure prorates over exactly those paychecks.
          next if allocs.any? && funding.any? && !funding.include?(date)

          scale = funding.empty? ? divisor : funding.size
          remaining = inflow[bank_id] || BigDecimal(0)
          results = {}
          per = allocation_results[date] ||= {}

          # 1. REQUIRED (bills/debts) — always first, best-effort.
          allocs.select { |a| a[:mode] == "required" }.each do |allocation|
            wanted = allocation_monthly(allocation) / scale
            got = remaining.positive? ? [ wanted, remaining ].min : BigDecimal(0)
            remaining -= got
            results[allocation[:id]] = { wanted: wanted, got: got, shortfall: [ wanted - got, BigDecimal(0) ].max, kind: allocation[:kind] }
          end

          # 2. SPECIFIC — the per-paycheck hard number.
          allocs.select { |a| a[:mode] == "specific" }.each do |allocation|
            wanted = allocation[:value_cents] || BigDecimal(0)
            got = remaining.positive? ? [ wanted, remaining ].min : BigDecimal(0)
            remaining -= got
            results[allocation[:id]] = { wanted: wanted, got: got, shortfall: [ wanted - got, BigDecimal(0) ].max, kind: allocation[:kind] }
          end

          # 3. PERCENT — a share of the bank's leftover pool (the residual
          #    after 1-2); each share comes off the shrinking residual.
          allocs.select { |a| a[:mode] == "percent" }.each do |allocation|
            wanted = remaining.positive? ? (remaining * allocation[:value_percent]).round(0, half: :up) : BigDecimal(0)
            got = remaining.positive? ? [ wanted, remaining ].min : BigDecimal(0)
            remaining -= got
            results[allocation[:id]] = { wanted: wanted, got: got, shortfall: [ wanted - got, BigDecimal(0) ].max, kind: allocation[:kind] }
          end

          # 4. LEFTOVER — the final residual, split equally (exact: the last
          #    share absorbs the remainder so the split sums to the residual).
          leftovers = allocs.select { |a| a[:mode] == "leftover" }
          if leftovers.size.positive?
            base = (remaining / leftovers.size).truncate(0)
            # The last share absorbs the remainder; compute every share off
            # the ORIGINAL residual before any mutation.
            shares = leftovers.each_index.map do |idx|
              idx == leftovers.size - 1 ? remaining - (leftovers.size - 1) * base : base
            end
            leftovers.each_with_index do |allocation, idx|
              share = shares[idx]
              got = share.positive? ? share : BigDecimal(0)
              shortfall = share.positive? ? BigDecimal(0) : -share
              results[allocation[:id]] = { wanted: share.positive? ? share : BigDecimal(0), got: got, shortfall: shortfall, kind: allocation[:kind] }
              remaining -= got
            end
          end

          per[bank_id] = results
          bank_surplus[date] ||= {}
          bank_surplus[date][bank_id] = remaining
        end
      end

      # Over-plan flags per income (monthly). Per paycheck: the income's
      # planned demand across the banks its funds reach — its share of each
      # bank's full demand (required wanted + specific + percent of the
      # post-bill pool) — minus the paycheck. Bills are assumed covered; the
      # gap is what the flag names against the fun money (if planned on a
      # reachable bank) or the surplus/savings line.
      over_plans = {}
      @incomes.each do |income|
        shortfall_month = BigDecimal(0)
        target_id = nil
        income[:occurrences].each do |occurrence|
          entry = @resolved[[ income[:id], occurrence[:date] ]]
          next unless entry

          date = occurrence[:date]
          demand = BigDecimal(0)
          leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
          bank_ids = entry[:amounts].keys
          bank_ids << leftover_edge[:account_id] if leftover_edge
          bank_ids.uniq.each do |bank_id|
            band = entry[:amounts].fetch(bank_id, BigDecimal(0))
            band += entry[:leftover] if leftover_edge && leftover_edge[:account_id] == bank_id
            inflow = (bank_inflow[date] || {})[bank_id] || BigDecimal(0)
            share = if inflow.positive? && band.positive?
              band / inflow
            elsif band.positive?
              BigDecimal(1)
            else
              BigDecimal(0)
            end
            next if share.zero?

            demand += share * ((demand_by_bank[date] || {})[bank_id] || BigDecimal(0))
            target_id ||= fun_targets_by_bank[date][bank_id]
          end

          gap = demand - occurrence[:amount_cents]
          shortfall_month += gap if gap.positive?
        end

        next unless shortfall_month.positive?

        over_plans[income[:id]] = {
          target: target_id ? "fun_money" : "surplus",
          target_id: target_id,
          shortfall: shortfall_month
        }
      end

      # Round 11 issue 8 (fan-out pool): the auto-transfer fan-out delivers
      # the parent's buckets from the parent's POST-ALLOCATION surplus — the
      # parent's own allocations resolved first above (bills pay first), so
      # when the parent is underfunded the bills take their share and the
      # buckets come up short, never the other way round (owner Q3: report
      # it, hide nothing). Per parent funding date each target — in
      # target-array order, which is the diagram's band order — draws
      # min(its prorated wanted, its share of the pool), share = the child's
      # required base over the sibling bases. A child WITH its own required
      # edges already resolved its own inflow in the main loop above (the
      # own-edge pool); the fan-out pool is independent and adds on top,
      # and its demand was counted exactly once — in the parent's required
      # base (graph_required_monthly) — so no double counting (owner Q2).
      @auto_transfer_targets.each do |parent_id, targets|
        parent_funding = bank_funding_dates.fetch(parent_id, [])
        next if parent_funding.empty? || targets.empty?

        bases = targets.map { |target_id| fan_out_child_base(target_id) }
        total_base = bases.sum
        parent_funding.each do |date|
          per = allocation_results[date] ||= {}
          # The parent's surplus AFTER its own allocations resolved on this
          # date; a negative residual (the bills outran the inflow) means
          # the fan-out pool is empty for the date.
          pool = [ (bank_surplus[date] || {})[parent_id] || BigDecimal(0), BigDecimal(0) ].max
          consumed_this_date = BigDecimal(0)

          targets.each_with_index do |target_id, index|
            child_allocs = @plan_allocations.select do |allocation|
              allocation[:mode] == "required" && allocation[:account_id] == target_id
            end

            # Record the wanted on EVERY parent funding date — a pool-empty
            # date still reports its proration as shortfall (nothing
            # hidden). The own-edge pool (main loop) may have recorded the
            # same allocation on this date already: it keeps its own
            # proration; the fan-out wanted is added only when the row did
            # not exist (no double count — owner Q2).
            child_results = per[target_id] ||= {}
            child_allocs.each do |allocation|
              wanted = allocation_monthly(allocation) / parent_funding.size
              next if wanted.zero? || child_results[allocation[:id]]
              child_results[allocation[:id]] = { wanted: wanted, got: BigDecimal(0),
                                                 shortfall: wanted, kind: allocation[:kind] }
            end

            share = if total_base.positive?
              bases[index] / total_base
            else
              BigDecimal(1) / targets.size
            end
            pool_share = pool.positive? ? (pool * share).round(0, half: :up) : BigDecimal(0)
            next if pool_share.zero?

            # Bills pay first: the transfer tops up the allocation's
            # unfunded wanted (capacity = wanted - got); anything beyond
            # the target accumulates in the child's bank as surplus, not
            # in the allocation row.
            remaining_share = pool_share
            absorbed = BigDecimal(0)
            child_allocs.each do |allocation|
              result = child_results[allocation[:id]]
              next if result.nil?

              absorb = [ remaining_share, result[:wanted] - result[:got] ].min
              next if absorb.zero?

              result[:got] += absorb
              result[:shortfall] -= absorb
              remaining_share -= absorb
              absorbed += absorb
            end
            consumed_this_date += pool_share
            excess = remaining_share
            if excess.positive?
              bank_surplus[date] ||= {}
              bank_surplus[date][target_id] = (bank_surplus[date][target_id] || BigDecimal(0)) + excess
            end
          end

          # The transfer is a real flow out of the parent: the parent's
          # post-allocation surplus reflects the fan-out consumption.
          if consumed_this_date.positive?
            bank_surplus[date] ||= {}
            bank_surplus[date][parent_id] = (bank_surplus[date][parent_id] || BigDecimal(0)) - consumed_this_date
          end
        end

        # Q3: the per-bucket shortfall lands on an over-plan line naming the
        # income that funds the parent and the FIRST unsatisfied bucket
        # (target-array order). Unsatisfied = the bucket's required
        # allocation is still short AFTER both pools (own-edge + fan-out) —
        # an income-level flag for the same income keeps priority, it
        # already names that income's gap.
        first_funding_date = parent_funding.min
        first_funding_income = @incomes.find do |income|
          income[:occurrences].any? { |occ| occ[:date] == first_funding_date } &&
            (@resolved[[ income[:id], first_funding_date ]] || {}).fetch(:amounts, {}).key?(parent_id)
        end
        next if first_funding_income.nil?

        targets.each do |target_id|
          child_allocs = @plan_allocations.select do |allocation|
            allocation[:mode] == "required" && allocation[:account_id] == target_id
          end
          next if child_allocs.empty?

          total_shortfall = dates.sum do |date|
            rows = (allocation_results[date] || {})[target_id] || {}
            child_allocs.sum { |allocation| rows[allocation[:id]]&.dig(:shortfall) || BigDecimal(0) }
          end
          next unless total_shortfall.positive?

          over_plans[first_funding_income[:id]] ||= {
            target: "bucket",
            target_id: target_id,
            shortfall: total_shortfall
          }
          break
        end
      end

      {
        dates: dates.sort,
        bands: bands,
        unallocated: unallocated,
        bank_inflow: bank_inflow,
        bank_surplus: bank_surplus,
        allocation_results: allocation_results,
        over_plans: over_plans
      }
    end

    # The required base per bank (monthly cents): the bank's required plan
    # allocations — explicit value_cents (a MONTHLY figure, prorated over the
    # month's paychecks like everything else here) when set, else the linked
    # transaction's monthly equivalent. A bank with no required plan
    # allocations keeps the legacy raw-bill obligations (the pre-redesign
    # behavior), so an empty allocation set reproduces the PR#1 numbers
    # exactly.
    #
    # Consequence: once a bank has required plan allocations, its required
    # base is those allocations ALONE — other detected bills on the bank are
    # surfaced by the recommendations query instead of silently flowing in.
    def graph_required_monthly
      required_monthly = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @plan_allocations.each do |allocation|
        next unless allocation[:mode] == "required"

        required_monthly[allocation[:account_id]] += allocation_monthly(allocation)
      end
      @obligations_by_account.each do |account_id, monthly|
        # The default block makes an absent key read as 0 (a truthy
        # BigDecimal), so `||=` would never assign — key? instead.
        required_monthly[account_id] = monthly unless required_monthly.key?(account_id)
      end
      # Round 11 issue 8 (fan-out): a parent's required base includes the
      # required base of every auto-transfer target — the reservation its
      # funding paychecks must cover for the buckets. required_edge_
      # funding_counts is UNCHANGED: the fan-out adds demand, not funding,
      # so required_per_paycheck[parent] prorates (own base + child bases)
      # over the parent's funding paychecks — the sum over them still lands
      # on the parent's total monthly base (the round 10 issue 1 invariant).
      @auto_transfer_targets.each do |parent_id, targets|
        required_monthly[parent_id] += targets.sum { |target_id| fan_out_child_base(target_id) }
      end
      required_monthly
    end

    # The required base (monthly cents) of one fan-out target: the child's
    # own required plan allocations via allocation_monthly when it has any,
    # else its raw-bill obligations — mirroring the graph_required_monthly
    # fallback (a child WITH required allocations never falls back, even to
    # 0).
    def fan_out_child_base(child_id)
      child_allocs = @plan_allocations.select do |allocation|
        allocation[:mode] == "required" && allocation[:account_id] == child_id
      end
      return child_allocs.sum { |allocation| allocation_monthly(allocation) } if child_allocs.any?

      @obligations_by_account.fetch(child_id, BigDecimal(0))
    end

    # The paycheck count that funds each bank at the edge level (plan_graph
    # only): the occurrences in the month of the incomes with a REQUIRED
    # edge to the bank. A bank's required base prorates over exactly these
    # paychecks -- summing the per-paycheck figure over them lands on the
    # monthly base, which is what the bank's allocations resolve against
    # (the dialog copy: "prorated over this month's paychecks" -- the
    # source bank's paychecks). A bank with no required edge receives no
    # reservation at all.
    def required_edge_funding_counts
      counts = Hash.new(0)
      @allocations.each do |edge|
        next unless edge[:mode] == "required"

        income = @incomes.find { |i| i[:id] == edge[:income_id] }
        counts[edge[:account_id]] += income ? income[:occurrences].size : 0
      end
      counts
    end

    # The required-mode monthly figure for one allocation: the explicit
    # value_cents when set, else the linked transaction's monthly equivalent
    # (the AR seam pre-resolves it into @required_amounts).
    def allocation_monthly(allocation)
      return BigDecimal(0) if allocation[:mode] != "required"

      amount = allocation[:value_cents]
      amount ||= allocation[:recurring_transaction_id] && @required_amounts[allocation[:recurring_transaction_id]]
      amount || BigDecimal(0)
    end

    def build_graph_report(graph:, allocations_by_bank:, divisor:, total_occurrences:, fix:)
      date_set = graph[:dates]

      # Incomes: occurrences, unallocated remainders, over-plan flags, and
      # the link-limit warnings (config-level, so declared-but-silent
      # paychecks still show them).
      incomes = @incomes.map do |income|
        unallocated_rows = graph[:unallocated].select { |row| row[:income_id] == income[:id] }
        unallocated_month = unallocated_rows.sum { |row| row[:amount] }
        over = graph[:over_plans][income[:id]]
        limit = @plan_max_links[income[:id]]
        linked = @linked_bank_counts[income[:id]].to_i

        {
          id: income[:id],
          name: income[:name],
          owner_id: income[:owner_id],
          occurrences: income[:occurrences].map do |occurrence|
            { date: occurrence[:date].to_s, amount: money(occurrence[:amount_cents]) }
          end,
          total_month: money(income[:occurrences].sum { |occurrence| occurrence[:amount_cents] }),
          unallocated_month: money(unallocated_month),
          unallocated: unallocated_rows.map { |row| { date: row[:date].to_s, amount: money(row[:amount]) } },
          over_plan: over && { target: over[:target], target_id: over[:target_id], shortfall_month: money(over[:shortfall]) },
          limit_warning: (limit && linked > limit) ? { linked_count: linked, limit: limit } : nil
        }
      end

      # Banks: the accounts the edges and the allocations touch (plus the
      # labeled role accounts and the plan-ordered accounts added via the
      # Add Account modal — owner review round 4: a plan-ordered bank with
      # no flow yet must still render, or it is a ghost: gone from the
      # add-accounts modal, invisible on the map, unreachable from the UI).
      # Unassigned allocations (account_id nil, owner review round 3, R3)
      # name no bank.
      # Round 11 issue 8: sub-accounts and fan-out targets get rows even
      # with no edge or allocation of their own — the sankey's child column
      # needs both endpoints of every fan-out band.
      bank_ids = (@allocations.map { |edge| edge[:account_id] } |
                  @plan_allocations.map { |allocation| allocation[:account_id] }.compact |
                  @plan_roles.keys |
                  @auto_transfers.keys |
                  @plan_ordered.keys |
                  @sub_account_links.keys |
                  @auto_transfer_targets.values.flatten).uniq

      banks = bank_ids.map do |bank_id|
        inflow_rows = graph[:bands].select { |band| band[:account_id] == bank_id }
        inflow_month = inflow_rows.sum { |band| band[:amount] }
        surplus_raw = graph[:dates].filter_map do |date|
          amount = (graph[:bank_surplus][date] || {})[bank_id]
          next if amount.nil? || amount.zero?

          [ date, amount ]
        end
        surplus_month = surplus_raw.sum { |_date, amount| amount }

        {
          id: bank_id,
          name: @account_names[bank_id],
          # Round 16 (owner note 4): the plaintext last-4 from the vendored
          # map; nil when the bank has no mask (never fabricated).
          last4: @account_last4s[bank_id],
          # Round 16 (owner note 3b): the logo slug — explicit per-account
          # override -> keyword match on the account name -> nil. The value
          # is always a slug from the vendored set (bank_logos), never a URL.
          logo: bank_logo_for(bank_id),
          plan_order: @plan_ordered[bank_id],
          plan_role: @plan_roles[bank_id],
          auto_transfer_to_account_id: @auto_transfers[bank_id],
          # Round 11 issue 8: the sub-account link + the ordered fan-out
          # targets (the legacy single-target key stays one more round).
          parent_account_id: @sub_account_links[bank_id],
          sub_account: @sub_account_links.key?(bank_id),
          auto_transfer_target_ids: @auto_transfer_targets[bank_id],
          inflow_month: money(inflow_month),
          inflow: inflow_rows.map do |band|
            { income_id: band[:income_id], date: band[:date].to_s, amount: money(band[:amount]) }
          end,
          surplus_month: money(surplus_month),
          surplus: surplus_raw.map { |date, amount| { date: date.to_s, amount: money(amount) } }
        }
      end

      # Allocations: the per-paycheck resolution plus the monthly rollup
      # (totals from the RAW cents, formatted only for display).
      over_plan_target_ids = graph[:over_plans].values.select { |over| over[:target] == "fun_money" }.map { |over| over[:target_id] }
      allocations = @plan_allocations.map do |allocation|
        account_id = allocation[:account_id]

        # Unassigned (owner review round 3, R3): the source bank was removed
        # from the plan. The allocation persists, is excluded from resolution,
        # and is reported with a zero footprint + status "unassigned" so the
        # diagram can draw it with a "No Assignment" marker (no flow band).
        if account_id.nil?
          next {
            id: allocation[:id],
            name: allocation[:name],
            kind: allocation[:kind],
            mode: allocation[:mode],
            value_cents: allocation[:value_cents] ? money(allocation[:value_cents]) : nil,
            value_percent: allocation[:value_percent] ? format("%.4f", allocation[:value_percent]) : nil,
            cadence: allocation[:cadence],
            recurring_transaction_id: allocation[:recurring_transaction_id],
            auto_transfer: allocation[:auto_transfer],
            # Round 16 (owner note 2): the Sure category's name + color so
            # the diagram band matches the category. nil / nil when the
            # allocation has no category (never a fabricated color).
            category_name: category_for(allocation[:category_id])[:name],
            category_color: category_for(allocation[:category_id])[:color],
            account_id: nil,
            per_paycheck: [],
            wanted_month: "0.00",
            got_month: "0.00",
            shortfall_month: "0.00",
            status: "unassigned",
            over_planned: false
          }
        end

        per_paycheck_raw = graph[:dates].filter_map do |date|
          result = (graph[:allocation_results][date] || {})[account_id]&.dig(allocation[:id])
          next unless result

          [ date, result ]
        end
        per_paycheck = per_paycheck_raw.map do |date, result|
          {
            date: date.to_s,
            wanted: money(result[:wanted]),
            got: money(result[:got]),
            shortfall: money(result[:shortfall]),
            status: allocation_status(result[:kind], result[:got], result[:shortfall])
          }
        end

        wanted_month = per_paycheck_raw.sum { |_date, result| result[:wanted] }
        got_month = per_paycheck_raw.sum { |_date, result| result[:got] }
        shortfall_month = wanted_month - got_month

        {
          id: allocation[:id],
          name: allocation[:name],
          kind: allocation[:kind],
          mode: allocation[:mode],
          value_cents: allocation[:value_cents] ? money(allocation[:value_cents]) : nil,
          value_percent: allocation[:value_percent] ? format("%.4f", allocation[:value_percent]) : nil,
          cadence: allocation[:cadence],
          recurring_transaction_id: allocation[:recurring_transaction_id],
          auto_transfer: allocation[:auto_transfer],
          # Round 16 (owner note 2): the Sure category's name + color so
          # the diagram band matches the category. nil / nil when the
          # allocation has no category (never a fabricated color).
          category_name: category_for(allocation[:category_id])[:name],
          category_color: category_for(allocation[:category_id])[:color],
          account_id: account_id,
          per_paycheck: per_paycheck,
          wanted_month: money(wanted_month),
          got_month: money(got_month),
          shortfall_month: money(shortfall_month),
          status: allocation_status(allocation[:kind], got_month, shortfall_month),
          # The RED node: the fun money the over-plan flag names, when it is
          # actually short.
          over_planned: over_plan_target_ids.include?(allocation[:id]) && shortfall_month.positive?
        }
      end

      {
        month: @month.strftime("%Y-%m"),
        currency: @currency,
        paycheck_dates: date_set.map(&:to_s),
        total_paychecks: total_occurrences,
        incomes: incomes,
        banks: banks,
        allocations: allocations,
        # Round 16 (owner note 3b): the full usable logo set at the payload
        # root, so the bank config dialog's searchable picker needs no new
        # endpoint (client-side filtering over this list).
        available_bank_logos: available_bank_logos_rows,
        over_plans: graph[:over_plans].map do |income_id, over|
          { income_id: income_id, target: over[:target], target_id: over[:target_id], shortfall_month: money(over[:shortfall]) }
        end,
        limit_warnings: incomes.reject { |income| income[:limit_warning].nil? }
                              .map { |income| { income_id: income[:id], **income[:limit_warning] } },
        recommendations: @recommendations,
        suggested_fix: format_fix(fix)
      }
    end

    # Round 16 (owner note 3b): the usable logo set as picker rows
    # ({ slug, label }), sorted by label for a readable dialog. bank_logos
    # is already the file+label intersection (BankLogoSlugs.available), so
    # every row here is a file the asset pipeline serves same-origin.
    def available_bank_logos_rows
      @bank_logos.sort_by { |slug, label| label.to_s.downcase }
                 .map { |slug, label| { slug: slug, label: label } }
    end

    # Round 16 (owner note 3b): the owner's resolution order — the explicit
    # per-account slug wins when usable; then the first keyword hit on the
    # account name (longest keyword first); otherwise nil. Only slugs from
    # the vendored set are ever emitted (never a broken <img>).
    def bank_logo_for(bank_id)
      explicit = @account_bank_logos[bank_id].to_s
      return explicit if @bank_logos.key?(explicit)

      name = @account_names[bank_id].to_s.downcase.gsub(/[^a-z0-9]/, "")
      return nil if name.empty?

      # Longest keyword first, GUARANTEED here (the spec's resolution order),
      # so the pure core does not trust the caller's input order.
      hit = bank_logo_keywords_longest_first.find { |keyword, _| name.include?(keyword) }
      return nil unless hit

      @bank_logos.key?(hit.last) ? hit.last : nil
    end

    # [keyword, slug] pairs sorted longest-keyword-first (the "navyfederal"
    # beats "navy" rule). BankLogoSlugs.keywords already sorts, but the
    # planner guarantees the order itself so the pure-core unit tests pass
    # with inputs in any order.
    def bank_logo_keywords_longest_first
      @bank_logo_keywords_longest_first ||=
        @bank_logo_keywords.sort_by { |keyword, _| -keyword.length }
    end

    # Round 16 (owner note 2): category id => { name, color } row; a missing
    # category reads as an empty hash so both lookups return nil (no
    # fabricated color).
    def category_for(category_id)
      category_id ? (@categories[category_id] || {}) : {}
    end

    def allocation_status(kind, got, shortfall)
      return "ok" if shortfall.zero?

      # Bills and debts cap at "partly": they are never the over-plan flag
      # target, so "over" is reserved for savings/fun_money.
      return "partly" if kind == "bill" || kind == "debt"

      got.zero? ? "over" : "partly"
    end

    def suggested_fix(deltas, partner_actual_month)
      candidate = deltas.max_by { |_partner, delta| delta }
      return nil unless candidate
      partner, delta = candidate
      return nil unless delta.positive?

      # The partner's percent edges, across all their streams. The one-variable
      # solve needs exactly one.
      edges = @allocations.select do |edge|
        edge[:mode] == "percent" && edge_incomes(edge).any? { |income| income[:owner_id] == partner }
      end
      return nil unless edges.size == 1

      edge = edges.first
      stream = @incomes.find { |income| income[:id] == edge[:income_id] }
      return nil unless stream

      stream_month = stream[:occurrences].sum { |occ| occ[:amount_cents] }
      return nil unless stream_month.positive?

      shift = delta / stream_month
      suggested = edge[:value_percent] + shift
      return nil unless suggested >= 0 && suggested <= 1

      {
        user_id: partner,
        income_series_id: edge[:income_id],
        account_id: edge[:account_id],
        current_percent: edge[:value_percent],
        suggested_percent: (suggested * 10_000).round(0, half: :up) / 10_000,
        new_leftover_month: partner_actual_month[partner] - delta
      }
    end

    def edge_incomes(edge)
      @incomes.select { |income| income[:id] == edge[:income_id] }
    end

    def build_report(by_date:, required_per_paycheck:, total_occurrences:, pool_month:,
                     weights:, deltas:, target:, spread:, fix:, shortfalls:, partner_actual_month:)
      accounts = (@allocations.map { |edge| edge[:account_id] } | @obligations_by_account.keys).uniq
      accounts_by_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      by_date.each_value do |bucket|
        bucket[:by_account].each { |account_id, amount| accounts_by_month[account_id] += amount }
      end

      {
        month: @month,
        paycheck_dates: by_date.keys.map(&:to_s).sort,
        total_paychecks: total_occurrences,
        accounts: accounts.map do |account_id|
          {
            id: account_id,
            required_month: money(@obligations_by_account.fetch(account_id, BigDecimal(0))),
            required_per_paycheck: money(required_per_paycheck.fetch(account_id, BigDecimal(0))),
            total_in_month: money(accounts_by_month[account_id])
          }
        end,
        paychecks: by_date.keys.sort.map do |date|
          bucket = by_date[date]
          allocations = resolved_allocations(date)
          {
            date: date.to_s,
            total_income: money(bucket[:total]),
            allocations: allocations,
            by_account: bucket[:by_account].transform_keys(&:to_s).transform_values { |v| money(v) }
          }
        end,
        leftover_attribution: {
          distribution: @leftover_distribution,
          pooled_per_paycheck: money(total_occurrences.positive? ? pool_month / total_occurrences : BigDecimal(0)),
          pooled_month: money(pool_month),
          by_partner: @partners.map do |partner|
            weight = weights[partner] || BigDecimal(0)
            {
              user_id: partner,
              weight: format("%.4f", weight),
              fun_money_per_paycheck: money(total_occurrences.positive? ? weight * pool_month / total_occurrences : BigDecimal(0)),
              fun_money_month: money(weight * pool_month),
              actual_leftover_month: money(partner_actual_month[partner])
            }
          end
        },
        delta: {
          target_month: money(target),
          spread_month: money(spread || BigDecimal(0)),
          by_partner: @partners.map do |partner|
            { user_id: partner, delta_month: money(deltas.fetch(partner, BigDecimal(0))) }
          end
        },
        suggested_fix: format_fix(fix),
        shortfalls: shortfalls.map do |income_id, gap|
          {
            income_series_id: income_id,
            gap_month: money(gap),
            message: "Required and fixed allocations exceed this income for #{month_label}"
          }
        end
      }
    end

    # Edge rows for one paycheck date, in the order the streams resolve.
    def resolved_allocations(date)
      rows = []
      @incomes.each do |income|
        next unless income[:occurrences].any? { |occ| occ[:date] == date }

        entry = @resolved[[ income[:id], date ]]
        entry[:amounts].each do |account_id, amount|
          mode = entry[:edges].find { |e| e[:account_id] == account_id }[:mode]
          rows << { income_series_id: income[:id], account_id: account_id, mode: mode, amount: money(amount) }
        end

        leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
        if leftover_edge
          rows << {
            income_series_id: income[:id],
            account_id: leftover_edge[:account_id],
            mode: "leftover",
            amount: money(entry[:leftover]),
            shortfall: entry[:leftover].negative?
          }
        end
      end
      rows
    end

    def format_fix(fix)
      return nil unless fix

      fix.merge(
        current_percent: format("%.4f", fix[:current_percent]),
        suggested_percent: format("%.4f", fix[:suggested_percent]),
        new_leftover_month: money(fix[:new_leftover_month])
      )
    end

    def money(cents)
      format("%.2f", cents / CENTS)
    end

    def month_label
      @month.strftime("%B %Y")
    end
end
