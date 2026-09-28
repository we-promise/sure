# Cash-flow Sankey split by account: income categories -> accounts -> expense
# categories. Each account's categories are netted exactly like the dashboard's
# category view (IncomeStatement#net_category_totals, top-level categories), just
# scoped to that one account. What an account takes in beyond what it spends
# flows on to Surplus; an account that spends more than it takes in (a credit
# card paid off by transfer, a savings account being drawn down) is fed from
# Deficit. Transfers between accounts are not income or spending, so they don't
# appear as flows between accounts.
#
# Emits the same { nodes:, links: } shape as PagesController's category Sankey,
# so sankey_chart_controller.js renders it unchanged.
class IncomeStatement::AccountSankey
  ACCOUNT_COLOR = "var(--color-gray-400)".freeze
  SURPLUS_COLOR = "var(--color-success)".freeze
  DEFICIT_COLOR = "var(--color-destructive)".freeze

  def initialize(family, accounts:, period:, user: Current.user)
    @family = family
    @accounts = accounts
    @period = period
    @user = user
  end

  def as_json(*)
    @nodes, @links, @node_indices = [], [], {}

    flows = account_flows
    total_income = flows.sum { |flow| flow[:totals].total_net_income }.to_d
    total_expense = flows.sum { |flow| flow[:totals].total_net_expense }.to_d

    flows.each { |flow| add_account_flows(flow, total_income, total_expense) }

    { nodes: @nodes, links: @links }
  end

  private
    attr_reader :family, :accounts, :period, :user

    def account_flows
      accounts.filter_map do |account|
        totals = family.income_statement(user: user, accounts: Account.where(id: account.id))
                       .net_category_totals(period: period)
        next if totals.total_net_income.zero? && totals.total_net_expense.zero?

        { account: account, totals: totals }
      end
    end

    def add_account_flows(flow, total_income, total_expense)
      account, totals = flow[:account], flow[:totals]
      income = totals.total_net_income.to_d
      expense = totals.total_net_expense.to_d
      account_idx = add_node("account_#{account.id}", account.name, [ income, expense ].max,
        percentage([ income, expense ].max, [ total_income, total_expense ].max), ACCOUNT_COLOR)

      totals.net_income_categories.each do |ct|
        category_idx = add_category_node("income", ct, total_income)
        add_link(category_idx, account_idx, ct.total, total_income, category_color(ct.category))
      end

      totals.net_expense_categories.each do |ct|
        category_idx = add_category_node("expense", ct, total_expense)
        add_link(account_idx, category_idx, ct.total, total_expense, category_color(ct.category))
      end

      net = income - expense
      if net.positive?
        surplus_idx = add_node("surplus_node", "Surplus", 0, 0, SURPLUS_COLOR)
        add_link(account_idx, surplus_idx, net, total_income, SURPLUS_COLOR)
      elsif net.negative?
        deficit_idx = add_node("deficit_node", "Deficit", 0, 0, DEFICIT_COLOR)
        add_link(deficit_idx, account_idx, net.abs, total_expense, DEFICIT_COLOR)
      end
    end

    # One node per category across all accounts; its value and share grow as
    # each account's flow into (or out of) it is added.
    def add_category_node(side, category_total, side_total)
      category = category_total.category
      key = category.uncategorized? ? "uncategorized" : (category.id || category.name)
      add_node("#{side}_#{key}", category.name, 0, 0, category_color(category),
        category.other_investments? ? nil : category.filter_value)
    end

    def add_node(id, name, value, pct, color, filter_value = nil)
      @node_indices[id] ||= begin
        @nodes << { id: id, name: name, filter_value: filter_value, value: value.to_f.round(2),
                    percentage: pct.to_f, color: color }
        @nodes.size - 1
      end
    end

    def add_link(source, target, value, side_total, color)
      amount = value.to_d
      return if amount.zero?

      pct = percentage(amount, side_total)
      @links << { source: source, target: target, value: amount.to_f.round(2), color: color, percentage: pct }
      [ source, target ].each do |index|
        node = @nodes[index]
        next if node[:id].start_with?("account_")

        node[:value] = (node[:value] + amount.to_f).round(2)
        node[:percentage] = percentage(node[:value], side_total)
      end
    end

    def category_color(category)
      category.color.presence || Category::UNCATEGORIZED_COLOR
    end

    def percentage(value, total)
      total.to_d.zero? ? 0.0 : (value.to_d / total.to_d * 100).round(1).to_f
    end
end
