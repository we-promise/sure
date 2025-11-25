class PagesController < ApplicationController
  include Periodable

  skip_authentication only: :redis_configuration_error

  def dashboard
    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.family.accounts.visible.with_attached_logo
    @include_investments = params[:include_investments] == "true"

    family_currency = Current.family.currency

    # Use the same period for all widgets (set by Periodable concern)
    income_totals = Current.family.income_statement.income_totals(period: @period)
    expense_totals = Current.family.income_statement.expense_totals(period: @period)

    # Get investment totals if include_investments is enabled
    investment_totals = @include_investments ? @investment_statement.totals(period: @period) : nil

    @cashflow_sankey_data = build_cashflow_sankey_data(income_totals, expense_totals, family_currency, investment_totals: investment_totals)
    @outflows_data = build_outflows_donut_data(expense_totals)

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
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
    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(income_totals, expense_totals, currency_symbol, investment_totals: nil)
      nodes = []
      links = []
      node_indices = {} # Memoize node indices by a unique key: "type_categoryid"

      # Helper to add/find node and return its index
      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          nodes << { name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income_val = income_totals.total.to_f.round(2)
      total_expense_val = expense_totals.total.to_f.round(2)

      # Add investment flows if enabled
      investment_contributions = investment_totals&.contributions&.amount&.to_f&.round(2) || 0
      investment_withdrawals = investment_totals&.withdrawals&.amount&.to_f&.round(2) || 0

      # Investment withdrawals are like income (cash coming in from selling)
      # Investment contributions are like expenses (cash going out to buy)
      total_income_with_investments = total_income_val + investment_withdrawals
      total_expense_with_investments = total_expense_val + investment_contributions

      # --- Create Central Cash Flow Node ---
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income_with_investments, 0, "var(--color-success)")

      # --- Process Income Side (Top-level categories only) ---
      income_totals.category_totals.each do |ct|
        # Skip subcategories – only include root income categories
        next if ct.category.parent_id.present?

        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage_of_total_income = total_income_with_investments.zero? ? 0 : (val / total_income_with_investments * 100).round(1)

        node_display_name = ct.category.name
        node_color = ct.category.color.presence || Category::COLORS.sample

        current_cat_idx = add_node.call(
          "income_#{ct.category.id}",
          node_display_name,
          val,
          percentage_of_total_income,
          node_color
        )

        links << {
          source: current_cat_idx,
          target: cash_flow_idx,
          value: val,
          color: node_color,
          percentage: percentage_of_total_income
        }
      end

      # --- Add Investment Withdrawals (Liquidations) as Income ---
      if investment_withdrawals.positive?
        percentage = total_income_with_investments.zero? ? 0 : (investment_withdrawals / total_income_with_investments * 100).round(1)
        inv_income_idx = add_node.call(
          "investment_liquidations",
          "Investment Liquidations",
          investment_withdrawals,
          percentage,
          Category::INVESTMENT_COLOR
        )

        links << {
          source: inv_income_idx,
          target: cash_flow_idx,
          value: investment_withdrawals,
          color: Category::INVESTMENT_COLOR,
          percentage: percentage
        }
      end

      # --- Process Expense Side (Top-level categories only) ---
      expense_totals.category_totals.each do |ct|
        # Skip subcategories – only include root expense categories to keep Sankey shallow
        next if ct.category.parent_id.present?

        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage_of_total_expense = total_expense_with_investments.zero? ? 0 : (val / total_expense_with_investments * 100).round(1)

        node_display_name = ct.category.name
        node_color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR

        current_cat_idx = add_node.call(
          "expense_#{ct.category.id}",
          node_display_name,
          val,
          percentage_of_total_expense,
          node_color
        )

        links << {
          source: cash_flow_idx,
          target: current_cat_idx,
          value: val,
          color: node_color,
          percentage: percentage_of_total_expense
        }
      end

      # --- Add Investment Contributions as Expense ---
      if investment_contributions.positive?
        percentage = total_expense_with_investments.zero? ? 0 : (investment_contributions / total_expense_with_investments * 100).round(1)
        inv_expense_idx = add_node.call(
          "investment_contributions",
          "Investment Contributions",
          investment_contributions,
          percentage,
          Category::INVESTMENT_COLOR
        )

        links << {
          source: cash_flow_idx,
          target: inv_expense_idx,
          value: investment_contributions,
          color: Category::INVESTMENT_COLOR,
          percentage: percentage
        }
      end

      # --- Process Surplus ---
      leftover = (total_income_with_investments - total_expense_with_investments).round(2)
      if leftover.positive?
        percentage_of_total_income_for_surplus = total_income_with_investments.zero? ? 0 : (leftover / total_income_with_investments * 100).round(1)
        surplus_idx = add_node.call("surplus_node", "Surplus", leftover, percentage_of_total_income_for_surplus, "var(--color-success)")
        links << { source: cash_flow_idx, target: surplus_idx, value: leftover, color: "var(--color-success)", percentage: percentage_of_total_income_for_surplus }
      end

      # Update Cash Flow and Income node percentages (relative to total income)
      if node_indices["cash_flow_node"]
        nodes[node_indices["cash_flow_node"]][:percentage] = 100.0
      end
      # No primary income node anymore, percentages are on individual income cats relative to total_income_val

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency_symbol).symbol }
    end

    def build_outflows_donut_data(expense_totals)
      currency_symbol = Money::Currency.new(expense_totals.currency).symbol
      total = expense_totals.total

      # Only include top-level categories with non-zero amounts
      categories = expense_totals.category_totals
        .reject { |ct| ct.category.parent_id.present? || ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon
          }
        end

      { categories: categories, total: total.to_f.round(2), currency_symbol: currency_symbol }
    end
end
