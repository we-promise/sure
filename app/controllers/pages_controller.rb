class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  def dashboard
    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.family.accounts.visible.with_attached_logo

    family_currency = Current.family.currency

    # Use IncomeStatement for all cashflow data (now includes categorized trades)
    income_totals = Current.family.income_statement.income_totals(period: @period)
    expense_totals = Current.family.income_statement.expense_totals(period: @period)

    @cashflow_sankey_data = build_cashflow_sankey_data(income_totals, expense_totals, family_currency)
    @outflows_data = build_outflows_donut_data(expense_totals)

    @dashboard_sections = build_dashboard_sections

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
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
          visible: Current.family.accounts.any?,
          collapsible: true
        },
        {
          key: "outflows_donut",
          title: "pages.dashboard.outflows_donut.title",
          partial: "pages/dashboard/outflows_donut",
          locals: { outflows_data: @outflows_data, period: @period },
          visible: Current.family.accounts.any? && @outflows_data[:categories].present?,
          collapsible: true
        },
        {
          key: "investment_summary",
          title: "pages.dashboard.investment_summary.title",
          partial: "pages/dashboard/investment_summary",
          locals: { investment_statement: @investment_statement, period: @period },
          visible: Current.family.accounts.any? && @investment_statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "net_worth_chart",
          title: "pages.dashboard.net_worth_chart.title",
          partial: "pages/dashboard/net_worth_chart",
          locals: { balance_sheet: @balance_sheet, period: @period },
          visible: Current.family.accounts.any?,
          collapsible: true
        },
        {
          key: "balance_sheet",
          title: "pages.dashboard.balance_sheet.title",
          partial: "pages/dashboard/balance_sheet",
          locals: { balance_sheet: @balance_sheet },
          visible: Current.family.accounts.any?,
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

    def build_cashflow_sankey_data(income_totals, expense_totals, currency)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          nodes << { name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income = income_totals.total.to_f.round(2)
      total_expense = expense_totals.total.to_f.round(2)

      # Central Cash Flow node
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income, 100.0, "var(--color-success)")

      # Income side (top-level categories only)
      income_totals.category_totals.each do |ct|
        next if ct.category.parent_id.present?

        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total_income.zero? ? 0 : (val / total_income * 100).round(1)
        color = ct.category.color.presence || Category::COLORS.sample

        idx = add_node.call("income_#{ct.category.id}", ct.category.name, val, percentage, color)
        links << { source: idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
      end

      # Expense side (top-level categories only)
      expense_totals.category_totals.each do |ct|
        next if ct.category.parent_id.present?

        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total_expense.zero? ? 0 : (val / total_expense * 100).round(1)
        color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR

        idx = add_node.call("expense_#{ct.category.id}", ct.category.name, val, percentage, color)
        links << { source: cash_flow_idx, target: idx, value: val, color: color, percentage: percentage }
      end

      # Surplus/Deficit
      net = (total_income - total_expense).round(2)
      if net.positive?
        percentage = total_income.zero? ? 0 : (net / total_income * 100).round(1)
        idx = add_node.call("surplus_node", "Surplus", net, percentage, "var(--color-success)")
        links << { source: cash_flow_idx, target: idx, value: net, color: "var(--color-success)", percentage: percentage }
      end

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency).symbol }
    end

    def build_outflows_donut_data(expense_totals)
      currency_symbol = Money::Currency.new(expense_totals.currency).symbol
      total = expense_totals.total

      categories = expense_totals.category_totals
        .reject { |ct| ct.category.parent_id.present? || ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: expense_totals.currency, currency_symbol: currency_symbol }
    end
end
