class PagesController < ApplicationController
  include Periodable

  skip_authentication only: %i[redis_configuration_error privacy terms]
  before_action :ensure_intro_guest!, only: :intro

  def dashboard
    if Current.user&.ui_layout_intro?
      redirect_to chats_path and return
    end

    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.user.accessible_accounts.visible.with_attached_logo

    family_currency = Current.family.currency

    # Use IncomeStatement for all cashflow data (now includes categorized trades)
    income_statement = Current.family.income_statement
    income_totals = income_statement.income_totals(period: @period)
    expense_totals = income_statement.expense_totals(period: @period)
    net_totals = income_statement.net_category_totals(period: @period)

    @cashflow_sankey_data = build_cashflow_sankey_data(net_totals, income_totals, expense_totals, family_currency)
    @outflows_data = build_outflows_donut_data(
      net_totals,
      investment_contributions_total: investment_contributions_outflow_total(@period)
    )

    @dashboard_sections = build_dashboard_sections

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
  end

  def intro
    @breadcrumbs = [ [ "Home", chats_path ], [ "Intro", nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: "Release notes unavailable",
        published_at: Date.current,
        body: "<p>Unable to fetch the latest release notes at this time. Please check back later or visit our <a href='https://github.com/we-promise/sure/releases' target='_blank'>GitHub releases page</a> directly.</p>"
      }
    end

    render layout: "settings"
  end

  def feedback
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
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections]
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order]
      end
    end

    def build_dashboard_sections
      all_sections = [
        {
          key: "cashflow_sankey",
          title: "pages.dashboard.cashflow_sankey.title",
          partial: "pages/dashboard/cashflow_sankey",
          locals: { sankey_data: @cashflow_sankey_data, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "outflows_donut",
          title: "pages.dashboard.outflows_donut.title",
          partial: "pages/dashboard/outflows_donut",
          locals: { outflows_data: @outflows_data, period: @period },
          visible: @accounts.any? && @outflows_data[:categories].present?,
          collapsible: true
        },
        {
          key: "investment_summary",
          title: "pages.dashboard.investment_summary.title",
          partial: "pages/dashboard/investment_summary",
          locals: { investment_statement: @investment_statement, period: @period },
          visible: @accounts.any? && @investment_statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "net_worth_chart",
          title: "pages.dashboard.net_worth_chart.title",
          partial: "pages/dashboard/net_worth_chart",
          locals: { balance_sheet: @balance_sheet, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "balance_sheet",
          title: "pages.dashboard.balance_sheet.title",
          partial: "pages/dashboard/balance_sheet",
          locals: { balance_sheet: @balance_sheet },
          visible: @accounts.any?,
          collapsible: true
        }
      ]

      # Order sections according to user preference
      section_order = Current.user.dashboard_section_order
      ordered_sections = section_order.map do |key|
        all_sections.find { |s| s[:key] == key }
      end.compact

      # Add any new sections that aren't in the saved order (future-proofing)
      all_sections.each do |section|
        ordered_sections << section unless ordered_sections.include?(section)
      end

      ordered_sections
    end

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(net_totals, income_totals, expense_totals, currency)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          nodes << { name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
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
          parent_idx = add_node.call(node_key, ct.category.name, val, percentage, color)

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
            sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color)

            if flow_direction == :inbound
              links << { source: sub_idx, target: parent_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            else
              links << { source: parent_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            end
          end
        else
          idx = add_node.call(node_key, ct.category.name, val, percentage, color)

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
          sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color)

          # Opposite direction: if parent is outbound (expense), this sub is inbound (income)
          if flow_direction == :inbound
            links << { source: cash_flow_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          else
            links << { source: sub_idx, target: cash_flow_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          end
        end
      end
    end

    def build_outflows_donut_data(net_totals, investment_contributions_total: 0)
      currency_symbol = Money::Currency.new(net_totals.currency).symbol
      total = net_totals.total_net_expense

      categories = net_totals.net_expense_categories
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      if investment_contributions_total.positive?
        investment_contributions_category = Current.family.investment_contributions_category
        categories << {
          id: investment_contributions_category.id,
          name: investment_contributions_category.name,
          amount: investment_contributions_total.to_f.round(2),
          currency: net_totals.currency,
          percentage: 0,
          color: investment_contributions_category.color.presence || Category::UNCATEGORIZED_COLOR,
          icon: investment_contributions_category.lucide_icon,
          clickable: true
        }
      end

      donut_total = total + investment_contributions_total
      categories = categories
        .reject { |category| category[:amount].zero? }
        .sort_by { |category| -category[:amount] }

      categories.each do |category|
        category[:percentage] = donut_total.zero? ? 0 : ((category[:amount] / donut_total) * 100).round(1)
      end

      { categories: categories, total: donut_total.to_f.round(2), currency: net_totals.currency, currency_symbol: currency_symbol }
    end

    def investment_contributions_outflow_total(period)
      scope = Current.family.transactions
        .visible
        .excluding_pending
        .in_period(period)
        .where(kind: "investment_contribution")
        .joins(entry: :account)
        .joins(<<~SQL.squish)
          LEFT JOIN exchange_rates er
            ON er.date = entries.date
            AND er.from_currency = entries.currency
            AND er.to_currency = #{ActiveRecord::Base.connection.quote(Current.family.currency)}
        SQL
        .merge(Account.included_in_finances_for(Current.user))

      scope.sum("ABS(entries.amount * COALESCE(er.rate, 1))")
    end

    def ensure_intro_guest!
      return if Current.user&.guest?

      redirect_to root_path, alert: t("pages.intro.not_authorized", default: "Intro is only available to guest users.")
    end
end
