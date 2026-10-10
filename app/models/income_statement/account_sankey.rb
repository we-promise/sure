# Cash-flow Sankey grouped by account: income categories -> accounts -> expense
# categories. Each account's categories are netted with IncomeStatement::
# CategoryNetting, scoped to that account. What an account takes in beyond what
# it spends flows on to Surplus; an account that spends more than it takes in
# (a credit card paid off by transfer, savings being drawn down) is fed from
# Deficit. Transfers between accounts are neither income nor spending, so they
# never appear as flows between accounts.
#
# Same schema as IncomeStatement::Sankey, with basis "net_by_account" and an
# "account" node kind in place of the single Cash Flow node.
class IncomeStatement::AccountSankey
  ACCOUNT_COLOR = "#737373".freeze

  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  def as_json(*)
    @nodes, @links, @node_index = [], [], {}
    flows = account_flows
    income = flows.sum { |flow| flow[:income] }.to_d
    spending = flows.sum { |flow| flow[:spending] }.to_d
    capacity = [ income, spending ].max
    unless capacity.zero?
      subcategory_flows = Hash.new(0.to_d)
      flows.each { |flow| add_account(flow, income, spending, capacity, subcategory_flows) }
      add_subcategories(subcategory_flows)
    end
    { basis: "net_by_account", income: decimal(income), spending: decimal(spending),
      net_savings: decimal(income - spending), nodes: @nodes.map { |node| serialize(node) }, links: @links }
  end

  private
    # Accounts the statement reports on, each with its own netting. One scoped
    # statement per account keeps the netting identical to the category view.
    def account_flows
      @statement.eligible_accounts.order(:name).filter_map do |account|
        statement = @statement.family.income_statement(user: @statement.user, accounts: Account.where(id: account.id))
        groups = IncomeStatement::CategoryNetting.new(statement, period: @period).groups
        income = groups.sum { |group| side_total(group, :income) }.to_d
        spending = groups.sum { |group| side_total(group, :expense) }.to_d
        next if income.zero? && spending.zero?

        { account: account, groups: groups, income: income, spending: spending }
      end
    end

    def add_account(flow, income, spending, capacity, subcategory_flows)
      account = flow[:account]
      size = [ flow[:income], flow[:spending] ].max
      center = node("account_#{account.id}", account.name, :account, color: ACCOUNT_COLOR)
      center[:value] = size
      center[:percentage] = percentage(size, capacity)

      flow[:groups].each do |group|
        { income: income, expense: spending }.each do |side, side_total|
          amount = side_total(group, side)
          next if amount.zero?

          category = group[:category]
          root = node("#{side}_#{category_key(category)}", category.name, side, category: category)
          root[:value] += amount
          root[:percentage] = percentage(root[:value], side_total)
          link(*(side == :income ? [ root, center ] : [ center, root ]), amount, percentage(amount, side_total))
          group[:children].each do |child|
            value = side_amount(child[:net], side)
            subcategory_flows[[ side, root[:id], child[:category] ]] += value unless value.zero?
          end
        end
      end

      net = flow[:income] - flow[:spending]
      return if net.zero?

      kind = net.positive? ? :surplus : :deficit
      balance = node("#{kind}_node", kind.to_s.capitalize, kind)
      balance[:value] += net.abs
      balance[:percentage] = percentage(balance[:value], capacity)
      link(*(net.positive? ? [ center, balance ] : [ balance, center ]), net.abs, percentage(net.abs, capacity))
    end

    # Subcategories are summed across accounts, then hang off their parent.
    def add_subcategories(subcategory_flows)
      subcategory_flows.each do |(side, root_id, category), value|
        root = @node_index.fetch(root_id)
        child = node("#{side}_sub_#{category.id}", category.name, side, category: category)
        child[:value] += value
        child[:percentage] = percentage(child[:value], root[:value])
        link(*(side == :income ? [ child, root ] : [ root, child ]), value, percentage(value, root[:value]))
      end
    end

    def node(id, name, kind, category: nil, color: category&.color)
      @node_index[id] ||= begin
        @nodes << { id: id, index: @nodes.size, name: name, kind: kind.to_s, value: 0.to_d, percentage: 0,
          category_id: category&.id, filter_value: category && !category.other_investments? ? category.filter_value : nil,
          color: color }
        @nodes.last
      end
    end

    def link(source, target, value, percentage)
      @links << { source: source[:index], target: target[:index], value: decimal(value), percentage: decimal(percentage) }
    end

    def serialize(node)
      node.except(:index).merge(value: decimal(node[:value]), percentage: decimal(node[:percentage]))
    end

    def category_key(category) = IncomeStatement::CategoryNetting.key(category)
    def side_amount(net, side) = IncomeStatement::CategoryNetting.side_amount(net, side)
    def side_total(group, side) = IncomeStatement::CategoryNetting.side_total(group, side)

    def percentage(value, total)
      total.zero? ? 0 : (value.to_d / total * 100).round(1)
    end

    def decimal(value)
      value.to_d.to_s("F")
    end
end
