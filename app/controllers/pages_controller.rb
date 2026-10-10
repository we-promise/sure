class PagesController < ApplicationController
  include Periodable

  # Per-widget dashboard layout guardrails. Deterministic defaults the masonry
  # packer reads; users may override a grow widget's height via presets.
  #   col_span:   "single" | "full" (full spans both columns in 2-col mode)
  #   grow:       true for charts that should fill an allotted height,
  #               false for content-sized widgets (tables, stat grids)
  #   min_height: floor in px
  DASHBOARD_SECTION_LAYOUTS = {
    # Width-toggleable but full by default: the feed is much shorter than any
    # other single-width widget, so defaulting to half leaves a grid hole the
    # masonry can't backfill (dense placement needs a later card short enough
    # to fit beside it, and none is). Users who pair it manually can go half.
    "insights_feed"      => { col_span: "full",   grow: false, min_height: 0, width_toggle: true },
    "cashflow_sankey"    => { col_span: "full",   grow: false, min_height: 384, width_toggle: true },
    "money_flow"         => { col_span: "single", grow: false, min_height: 0,   width_toggle: true },
    "spending_trend"     => { col_span: "single", grow: true,  min_height: 208, width_toggle: true },
    "outflows_donut"     => { col_span: "single", grow: false, min_height: 0 },
    "investment_summary" => { col_span: "single", grow: false, min_height: 0, width_toggle: true },
    "net_worth_chart"    => { col_span: "single", grow: true,  min_height: 208, width_toggle: true },
    "balance_sheet"      => { col_span: "single", grow: false, min_height: 0, width_toggle: true },
    "liquidity"          => { col_span: "single", grow: false, min_height: 0, width_toggle: true }
  }.freeze

  # Number of consecutive months (ending at the selected month) shown as
  # bars in the "money_flow" dashboard widget.
  MONEY_FLOW_CHART_MONTHS = 6

  # Query params that shape what the dashboard shows without being saved
  # anywhere. Customize mode carries them through its links and hide/add
  # buttons so the widgets don't jump back to their defaults.
  DASHBOARD_VIEW_PARAMS = [ :start_date, :end_date, :money_flow_month, :spending_month, { money_flow_account_ids: [] } ].freeze

  # Widgets only preview users see; for everyone else they are left out of
  # the section list, including the hidden list.
  PREVIEW_DASHBOARD_SECTIONS = %w[insights_feed liquidity].freeze

  # Selectable height presets (px) for grow widgets.
  DASHBOARD_HEIGHT_PRESETS = { "compact" => 208, "auto" => 288, "tall" => 416 }.freeze
  DEFAULT_HEIGHT_PRESET = "auto"

  skip_authentication only: %i[redis_configuration_error privacy terms]
  before_action :ensure_intro_guest!, only: :intro

  def dashboard
    if Current.user&.ui_layout_intro?
      redirect_to chats_path and return
    end

    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.user.accessible_accounts.visible.with_attached_logo

    @dashboard_sections, @hidden_dashboard_sections = build_dashboard_sections
    @customizing_dashboard = params[:customize].present?
    @dashboard_view_params = dashboard_view_params
    @just_hidden_section = params[:hidden_section]
    @just_shown_section = params[:shown_section]

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.dashboard"), nil ] ]
  end

  def intro
    @breadcrumbs = [ [ t("breadcrumbs.home"), chats_path ], [ t("breadcrumbs.intro"), nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params, laid_out_order: ordered_dashboard_section_keys)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def update_section_hidden
    section_key = params[:section_key]
    return head :not_found unless DASHBOARD_SECTION_LAYOUTS.key?(section_key)

    hidden = ActiveModel::Type::Boolean.new.cast(params[:hidden])
    Current.user.update_dashboard_section_hidden(section_key, hidden)
    # Two param names rather than one, so hiding a widget and adding it back
    # never redirect to the same URL: Turbo morphs a same-URL visit as a
    # refresh, and a morph doesn't apply the autofocus that keeps keyboard
    # users on the widget they just changed.
    changed = hidden ? { hidden_section: section_key } : { shown_section: section_key }
    redirect_to root_path(dashboard_view_params.merge(customize: true, **changed)), status: :see_other
  end

  # Hides the one-time "please check how your accounts were classified"
  # hint in the availability widget.
  def dismiss_liquidity_review
    Current.user.dismiss_liquidity_review!
    redirect_to root_path(dashboard_view_params), status: :see_other
  end

  def changelog
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.changelog"), nil ] ]
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: t("pages.release_notes_unavailable.name"),
        published_at: Date.current,
        body: t("pages.release_notes_unavailable.body_html")
      }
    end

    render layout: "settings"
  end

  def feedback
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.feedback"), nil ] ]
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  def privacy
    render layout: "blank"
  end

  def terms
    render layout: "blank"
  end

  private
    def preferences_params
      prefs = params.require(:preferences)
      {}.tap do |permitted|
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections].respond_to?(:to_unsafe_h)
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order].is_a?(Array)
        permitted["dashboard_section_layout"] = prefs[:dashboard_section_layout].to_unsafe_h if prefs[:dashboard_section_layout].respond_to?(:to_unsafe_h)
        permitted["cashflow_sankey_group_by"] = prefs[:cashflow_sankey_group_by] if User::CASHFLOW_SANKEY_GROUPINGS.include?(prefs[:cashflow_sankey_group_by])
      end
    end

    def dashboard_view_params
      params.permit(*DASHBOARD_VIEW_PARAMS).to_h
    end

    # Each widget builds its own data, so a hidden widget's builder is never
    # called and its queries never run.
    def dashboard_section_builders
      {
        "insights_feed" => -> { insights_feed_section },
        "cashflow_sankey" => -> {
          {
            key: "cashflow_sankey",
            title: "pages.dashboard.cashflow_sankey.title",
            partial: "pages/dashboard/cashflow_sankey",
            layout: section_layout("cashflow_sankey"),
            locals: { sankey_data: cashflow_sankey_data, period: @period },
            visible: @accounts.any?,
            collapsible: true
          }
        },
        "money_flow" => -> {
          accounts = dashboard_income_statement.eligible_accounts
          {
            key: "money_flow",
            title: "pages.dashboard.money_flow.title",
            partial: "pages/dashboard/money_flow",
            layout: section_layout("money_flow"),
            locals: {
              money_flow_data: build_money_flow_data(dashboard_income_statement, money_flow_month_param, money_flow_account_ids_param(accounts)),
              accounts: accounts,
              # TransactionsController's default (account_ids absent) scopes
              # to this broader set, not `accounts`, so the view needs it to
              # know when the drill-down links can safely omit account_ids.
              accessible_account_ids: Current.user.accessible_accounts.pluck(:id).map(&:to_s),
              col_span: section_layout("money_flow")[:col_span]
            },
            visible: @accounts.any?,
            collapsible: true
          }
        },
        "spending_trend" => -> {
          {
            key: "spending_trend",
            title: "pages.dashboard.spending_trend.title",
            partial: "pages/dashboard/spending_trend",
            layout: section_layout("spending_trend"),
            locals: { spending_trend_data: build_spending_trend_data(dashboard_income_statement, spending_trend_month_param) },
            visible: @accounts.any?,
            collapsible: true
          }
        },
        "outflows_donut" => -> {
          outflows_data = build_outflows_donut_data(dashboard_net_totals)
          {
            key: "outflows_donut",
            title: "pages.dashboard.outflows_donut.title",
            partial: "pages/dashboard/outflows_donut",
            layout: section_layout("outflows_donut"),
            locals: { outflows_data: outflows_data, period: @period },
            visible: @accounts.any? && outflows_data[:categories].present?,
            collapsible: true
          }
        },
        "investment_summary" => -> {
          {
            key: "investment_summary",
            title: "pages.dashboard.investment_summary.title",
            partial: "pages/dashboard/investment_summary",
            layout: section_layout("investment_summary"),
            locals: { investment_statement: @investment_statement, period: @period },
            visible: investment_summary_available?,
            collapsible: true
          }
        },
        "net_worth_chart" => -> {
          {
            key: "net_worth_chart",
            title: "pages.dashboard.net_worth_chart.title",
            partial: "pages/dashboard/net_worth_chart",
            layout: section_layout("net_worth_chart"),
            locals: { balance_sheet: @balance_sheet, period: @period },
            visible: @accounts.any?,
            collapsible: true
          }
        },
        "balance_sheet" => -> {
          {
            key: "balance_sheet",
            title: "pages.dashboard.balance_sheet.title",
            partial: "pages/dashboard/balance_sheet",
            layout: section_layout("balance_sheet"),
            locals: { balance_sheet: @balance_sheet },
            visible: @accounts.any?,
            collapsible: true
          }
        },
        "liquidity" => -> { liquidity_section }
      }
    end

    # Just enough for the hidden list, without running the widget's queries.
    # Widgets whose data depends on the period stay on offer, since another
    # period may have something to show. Without investment accounts the
    # investment summary never has anything to show, and without insights
    # neither does the feed.
    def hidden_dashboard_section(key)
      return nil if key.in?(PREVIEW_DASHBOARD_SECTIONS) && !preview_features_enabled?

      visible = case key
      when "investment_summary" then investment_summary_available?
      when "insights_feed" then Current.family.insights.visible.exists?
      else @accounts.any?
      end

      { key: key, title: "pages.dashboard.#{key}.title", visible: visible }
    end

    def investment_summary_available?
      @accounts.any? && @investment_statement.investment_accounts.any?
    end

    # Use IncomeStatement for all cashflow data (now includes categorized trades)
    def dashboard_income_statement
      @dashboard_income_statement ||= Current.family.income_statement
    end

    def dashboard_net_totals
      @dashboard_net_totals ||= dashboard_income_statement.net_category_totals(period: @period)
    end

    def cashflow_sankey_data
      build_cashflow_sankey_data(
        dashboard_net_totals,
        dashboard_income_statement.income_totals(period: @period),
        dashboard_income_statement.expense_totals(period: @period),
        Current.family.currency
      )
    end

    # Preview-gated, and omitted from the section list entirely rather than
    # left in it with `visible: false`. Dropping it here means the two
    # downstream behaviors fall out for free: the saved-order lookup finds
    # nothing to map, and the insights_feed unshift special-case never fires.
    def insights_feed_section
      return nil unless preview_features_enabled?

      insights = Current.family.insights.visible.ordered.limit(Insight::FEED_LIMIT)
      {
        key: "insights_feed",
        title: "pages.dashboard.insights_feed.title",
        partial: "pages/dashboard/insights_feed",
        layout: section_layout("insights_feed"),
        locals: { insights: insights },
        visible: insights.any?,
        collapsible: true
      }
    end

    # Available vs. locked wealth and when locked money is released
    # (Account::Liquidity). Preview-gated like the insights feed.
    def liquidity_section
      return nil unless preview_features_enabled?

      {
        key: "liquidity",
        title: "pages.dashboard.liquidity.title",
        partial: "pages/dashboard/liquidity",
        layout: section_layout("liquidity"),
        locals: { balance_sheet: @balance_sheet, period: @period },
        visible: @accounts.any?,
        collapsible: true
      }
    end

    def build_dashboard_sections
      hidden_keys = Current.user.dashboard_hidden_sections
      builders = dashboard_section_builders
      sections = ordered_dashboard_section_keys.filter_map do |key|
        hidden_keys.include?(key) ? hidden_dashboard_section(key) : builders.fetch(key).call
      end

      # Returns [shown, hidden]. Sections with nothing to show are dropped
      # first, so the hidden list never offers back a widget that wouldn't
      # appear once re-added.
      hidden, shown = sections.select { |s| s[:visible] }.partition { |s| hidden_keys.include?(s[:key]) }
      [ shown, hidden ]
    end

    # The order the dashboard lays its widgets out in: the user's saved order,
    # then any widget missing from it (future-proofing). The insights feed
    # leads instead of appending: it's a proactive surface, and appending
    # would bury it below the fold for every family with a saved order. Users
    # can still drag it back down — that choice persists.
    def ordered_dashboard_section_keys
      keys = dashboard_section_builders.keys
      saved = Current.user.dashboard_section_order & keys
      unsaved = keys - saved
      (unsaved & %w[insights_feed]) + saved + (unsaved - %w[insights_feed])
    end

    # Resolves a section's layout guardrails, applying the user's height preset
    # override (falling back to the deterministic default) for grow widgets.
    def section_layout(key)
      base = DASHBOARD_SECTION_LAYOUTS.fetch(key, { col_span: "single", grow: false, min_height: 0, width_toggle: false })
      preset = Current.user.dashboard_section_height(key)
      preset = DEFAULT_HEIGHT_PRESET unless DASHBOARD_HEIGHT_PRESETS.key?(preset)

      col_span = base[:col_span]
      if base[:width_toggle]
        user_span = Current.user.dashboard_section_width(key)
        col_span = user_span if %w[single full].include?(user_span)
      end

      base.merge(col_span: col_span, height_preset: preset, height_px: DASHBOARD_HEIGHT_PRESETS.fetch(preset))
    end

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(net_totals, income_totals, expense_totals, currency)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(unique_key, display_name, value, percentage, color, filter_value = nil) {
        node_indices[unique_key] ||= begin
          nodes << { id: unique_key, name: display_name, filter_value: filter_value, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income = net_totals.total_net_income.to_f.round(2)
      total_expense = net_totals.total_net_expense.to_f.round(2)

      # Central Cash Flow node
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income, 100.0, "var(--color-success)")

      # Build netted subcategory data from raw totals
      net_subcategories_by_parent = build_net_subcategories(expense_totals, income_totals)

      # Process net income categories (flow: subcategory -> parent -> cash_flow)
      process_net_category_nodes(
        categories: net_totals.net_income_categories,
        total: total_income,
        prefix: "income",
        net_subcategories_by_parent: net_subcategories_by_parent,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx,
        flow_direction: :inbound
      )

      # Process net expense categories (flow: cash_flow -> parent -> subcategory)
      process_net_category_nodes(
        categories: net_totals.net_expense_categories,
        total: total_expense,
        prefix: "expense",
        net_subcategories_by_parent: net_subcategories_by_parent,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx,
        flow_direction: :outbound
      )

      # Surplus/Deficit
      net = (total_income - total_expense).round(2)
      if net.positive?
        percentage = total_income.zero? ? 0 : (net / total_income * 100).round(1)
        idx = add_node.call("surplus_node", "Surplus", net, percentage, "var(--color-success)")
        links << { source: cash_flow_idx, target: idx, value: net, color: "var(--color-success)", percentage: percentage }
      end

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency).symbol }
    end

    # Nets subcategory expense and income totals, grouped by parent_id.
    # Returns { parent_id => [ { category:, total: net_amount }, ... ] }
    # Only includes subcategories with positive net (same direction as parent).
    def build_net_subcategories(expense_totals, income_totals)
      expense_subs = expense_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      income_subs = income_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      all_sub_ids = (expense_subs.keys + income_subs.keys).uniq
      result = {}

      all_sub_ids.each do |sub_id|
        exp_ct = expense_subs[sub_id]
        inc_ct = income_subs[sub_id]
        exp_total = exp_ct&.total || 0
        inc_total = inc_ct&.total || 0
        net = exp_total - inc_total
        category = exp_ct&.category || inc_ct&.category

        next if net.zero?

        parent_id = category.parent_id
        result[parent_id] ||= []
        result[parent_id] << { category: category, total: net.abs, net_direction: net > 0 ? :expense : :income }
      end

      result
    end

    # Builds sankey nodes/links for net categories with subcategory hierarchy.
    # Subcategories matching the parent's flow direction are shown as children.
    # Subcategories with opposite net direction appear on the OTHER side of the
    # sankey (handled when the other side calls this method).
    #
    # flow_direction: :inbound  (subcategory -> parent -> cash_flow) for income
    #                 :outbound (cash_flow -> parent -> subcategory) for expenses
    def process_net_category_nodes(categories:, total:, prefix:, net_subcategories_by_parent:, add_node:, links:, cash_flow_idx:, flow_direction:)
      matching_direction = flow_direction == :inbound ? :income : :expense

      categories.each do |ct|
        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total.zero? ? 0 : (val / total * 100).round(1)
        color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR
        node_key = "#{prefix}_#{ct.category.id || ct.category.name}"

        all_subs = ct.category.id ? (net_subcategories_by_parent[ct.category.id] || []) : []
        same_side_subs = all_subs.select { |s| s[:net_direction] == matching_direction }

        # Also check if any subcategory has opposite direction — those will be
        # rendered by the OTHER side's call to this method, linked to cash_flow
        # directly (they appear as independent nodes on the opposite side).
        opposite_subs = all_subs.select { |s| s[:net_direction] != matching_direction }

        if same_side_subs.any?
          parent_idx = add_node.call(node_key, ct.category.name, val, percentage, color, ct.category.filter_value)

          if flow_direction == :inbound
            links << { source: parent_idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: parent_idx, value: val, color: color, percentage: percentage }
          end

          same_side_subs.each do |sub|
            sub_val = sub[:total].to_f.round(2)
            sub_pct = val.zero? ? 0 : (sub_val / val * 100).round(1)
            sub_color = sub[:category].color.presence || color
            sub_key = "#{prefix}_sub_#{sub[:category].id}"
            sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color, sub[:category].filter_value)

            if flow_direction == :inbound
              links << { source: sub_idx, target: parent_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            else
              links << { source: parent_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            end
          end
        else
          idx = add_node.call(node_key, ct.category.name, val, percentage, color, ct.category.filter_value)

          if flow_direction == :inbound
            links << { source: idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: idx, value: val, color: color, percentage: percentage }
          end
        end

        # Render opposite-direction subcategories as standalone nodes on this side,
        # linked directly to cash_flow. They represent subcategory surplus/deficit
        # that goes against the parent's overall direction.
        opposite_prefix = flow_direction == :inbound ? "expense" : "income"
        opposite_subs.each do |sub|
          sub_val = sub[:total].to_f.round(2)
          sub_pct = total.zero? ? 0 : (sub_val / total * 100).round(1)
          sub_color = sub[:category].color.presence || color
          sub_key = "#{opposite_prefix}_sub_#{sub[:category].id}"
          sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color, sub[:category].filter_value)

          # Opposite direction: if parent is outbound (expense), this sub is inbound (income)
          if flow_direction == :inbound
            links << { source: cash_flow_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          else
            links << { source: sub_idx, target: cash_flow_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          end
        end
      end
    end

    def build_outflows_donut_data(net_totals)
      currency_symbol = Money::Currency.new(net_totals.currency).symbol
      total = net_totals.total_net_expense

      categories = net_totals.net_expense_categories
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            filter_value: ct.category.filter_value,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: net_totals.currency, currency_symbol: currency_symbol }
    end

    def money_flow_month_param
      current_month = Date.current.beginning_of_month
      month = Date.strptime(params[:money_flow_month], "%Y-%m-%d").beginning_of_month
      # Clamp future months: build_money_flow_data caps each bar's end_date at
      # Date.current, which would otherwise be earlier than a future month's
      # start_date and blow up Period.custom's date-range validation.
      month > current_month ? current_month : month
    rescue ArgumentError, TypeError
      current_month
    end

    # nil means "all accessible accounts" (the widget's default, unfiltered state)
    def money_flow_account_ids_param(eligible_accounts)
      ids = Array(params[:money_flow_account_ids]).reject(&:blank?)
      eligible_ids = eligible_accounts.map { |a| a.id.to_s }
      ids &= eligible_ids
      ids.presence
    end

    def spending_trend_month_param
      current_month = Date.current.beginning_of_month
      month = Date.strptime(params[:spending_month], "%Y-%m-%d").beginning_of_month
      # Same clamp as money_flow: a future month's period would end before it
      # starts once capped at Date.current, which Period.custom rejects.
      month > current_month ? current_month : month
    rescue ArgumentError, TypeError
      current_month
    end

    # Cumulative daily spending for the selected month (capped at today while
    # the month is in progress) against the previous month's full curve, so
    # the two lines share one day-of-month axis. The header totals compare the
    # same number of elapsed days; only the chart draws the previous month out
    # to its final day.
    def build_spending_trend_data(income_statement, selected_month)
      month_start = selected_month.beginning_of_month
      month_end = month_start.end_of_month
      current_period = Period.custom(start_date: month_start, end_date: [ month_end, Date.current ].min)

      previous_month_start = (month_start - 1.month).beginning_of_month
      previous_period = Period.custom(start_date: previous_month_start, end_date: previous_month_start.end_of_month)

      current_daily = income_statement.daily_expense_series(period: current_period).index_by(&:date)
      previous_daily = income_statement.daily_expense_series(period: previous_period).index_by(&:date)

      # The selected month always owns the axis: when the previous month is
      # longer, its extra days fold into the final visible point so the curve
      # still ends at the full-month total without the axis rolling into
      # previous-month dates (e.g. a September view ends at "Sep 30", not
      # "Aug 31").
      axis_days = month_end.day

      current_series = cumulative_spending_series(current_period, current_daily)
      previous_header_series = cumulative_spending_series(previous_period, previous_daily)
      previous_series = fold_extra_days(previous_header_series, axis_days)

      current_total = current_series.last&.fetch(:value) || 0
      comparison_days = if month_start == Date.current.beginning_of_month
        [ current_series.size, previous_header_series.size ].min
      else
        previous_header_series.size
      end
      previous_total = comparison_days.positive? ? previous_header_series[comparison_days - 1][:value] : 0
      previous_comparison_day = comparison_days if comparison_days.positive? && comparison_days < previous_header_series.size
      currency = income_statement.family.currency


      {
        month: month_start,
        current_period: current_period,
        previous_period: previous_period,
        days: axis_days,
        current_days: month_end.day,
        axis_labels: spending_trend_axis_labels(month_start, axis_days),
        current: current_series,
        previous: previous_series,
        current_total: Money.new(current_total, currency),
        previous_total: Money.new(previous_total, currency),
        delta: Money.new(current_total - previous_total, currency),
        previous_label: I18n.l(previous_month_start, format: :month_year).capitalize,
        previous_comparison_day: previous_comparison_day,
        date_range_short: spending_trend_compact_date_range(current_period)
      }
    end

    # Compact range for narrow viewports ("Sep 01 - 6, 2026"). The period
    # never spans months, so the end date only needs its day.
    def spending_trend_compact_date_range(period)
      date_range = period.date_range

      if date_range.begin == date_range.end
        t("pages.dashboard.spending_trend.date_range_short_single",
          date: I18n.l(date_range.begin, format: :short),
          year: date_range.end.year)
      else
        t("pages.dashboard.spending_trend.date_range_short",
          start_date: I18n.l(date_range.begin, format: :short),
          end_day: date_range.end.day,
          year: date_range.end.year)
      end
    end

    # Localized tick labels, one per axis day. The axis always spans exactly
    # the selected month, so labels never roll into the previous month.
    def spending_trend_axis_labels(month_start, days)
      (1..days).map do |day|
        I18n.l(month_start + (day - 1), format: :short)
      end
    end

    # A longer previous month's curve is clipped to the axis, with the extra
    # days' spend folded into the final visible point, so the curve still
    # ends at the full-month total shown in the header. The folded point
    # keeps its axis slot (day) for positioning but carries the true
    # endpoint's date metadata, so the tooltip says what the value actually
    # contains (e.g. "Jan 31" and the total through Jan 31).
    def fold_extra_days(series, axis_days)
      return series if series.size <= axis_days

      series.first(axis_days).tap do |folded|
        folded[-1] = folded[-1].merge(
          value: series.last[:value],
          date: series.last[:date],
          date_formatted: series.last[:date_formatted]
        )
      end
    end

    # One point per day (spend-free days included) so flat stretches render
    # flat instead of being interpolated away.
    def cumulative_spending_series(period, daily_totals)
      cumulative = 0.to_d
      period.date_range.map do |date|
        cumulative += daily_totals[date] ? daily_totals[date].total.to_d : 0
        {
          day: (date - period.start_date).to_i + 1,
          value: cumulative.to_f.round(2),
          date: date.iso8601,
          date_formatted: I18n.l(date, format: :short)
        }
      end
    end

    def build_money_flow_data(income_statement, selected_month, account_ids)
      months = (MONEY_FLOW_CHART_MONTHS - 1).downto(0).map { |i| selected_month - i.months }

      selected_period = nil
      selected_totals = nil

      bars = months.map do |month_start|
        # Cap at today so an in-progress month (most commonly the current one)
        # doesn't report totals for its not-yet-arrived days.
        end_date = [ month_start.end_of_month, Date.current ].min
        period = Period.custom(start_date: month_start, end_date: end_date)
        totals = income_statement.totals_for(period, account_ids: account_ids)

        if month_start == selected_month
          selected_period = period
          selected_totals = totals
        end

        {
          date: month_start,
          label: I18n.l(month_start, format: :short_month_year),
          # Fallback for the axis when the full label does not fit its band.
          # `short_month_year` is only short in some locales — "Mar 2026" in
          # English, but "Mar de 2026" in ca/es/pt, which is wide enough to
          # collide with its neighbours on a phone. The bar chart measures the
          # rendered labels and drops to this when they overlap.
          short_label: I18n.l(month_start, format: "%b"),
          income: totals.income_money.amount.to_f.round(2),
          expense: totals.expense_money.amount.to_f.round(2),
          highlighted: month_start == selected_month,
          partial: end_date < month_start.end_of_month
        }
      end

      {
        bars: bars,
        period: selected_period,
        month: selected_month,
        income: selected_totals.income_money,
        expense: selected_totals.expense_money,
        balance: selected_totals.income_money - selected_totals.expense_money,
        account_ids: account_ids
      }
    end

    def ensure_intro_guest!
      return if Current.user&.guest?

      redirect_to root_path, alert: t("pages.intro.not_authorized", default: "Intro is only available to guest users.")
    end
end
