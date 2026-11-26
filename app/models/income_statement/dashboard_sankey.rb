# The dashboard's cash flow Sankey: income categories -> Cash Flow -> expense
# categories, netted with IncomeStatement::CategoryNetting. A category sits on
# the side its net amount falls, sized to what it has on that side, with its
# subcategories and its own share branching off it. Anything running the other
# way (a subcategory refunded more than was spent, a refund on the category
# itself) is its own node on the other side, linked to Cash Flow directly.
#
# Values are whole cents, so every node passes on exactly what it takes in,
# and Surplus or Deficit is the period's net rounded once (see #to_cents).
class IncomeStatement::DashboardSankey
  SUCCESS_COLOR = "var(--color-success)".freeze
  DESTRUCTIVE_COLOR = "var(--color-destructive)".freeze

  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  def as_json(*)
    @nodes, @links, @node_indices = [], [], {}
    flows, invested = rounded_flows
    income = flows.select { |flow| flow[:side] == :income }.sum(0.to_d) { |flow| flow[:value] }
    spending = flows.select { |flow| flow[:side] == :expense }.sum(0.to_d) { |flow| flow[:value] }

    # Sized to whichever side is larger, so a deficit still balances
    capacity = [ income, spending + invested ].max
    center = add_node("cash_flow_node", "Cash Flow", capacity, 100, SUCCESS_COLOR)

    flows.each do |flow|
      category = flow[:category]
      color = category.color.presence || Category::UNCATEGORIZED_COLOR
      percentage = share(flow[:value], flow[:side] == :income ? income : spending)
      index = add_node(flow[:id], flow[:name], flow[:value], percentage, color, category.filter_value)
      add_flow(flow[:side], center, index, flow[:value], color, percentage)

      flow[:branches].each do |branch|
        branch_color = branch[:category].color.presence || color
        branch_percentage = share(branch[:amount], flow[:value])
        branch_index = add_node(branch[:id], branch[:name], branch[:amount], branch_percentage, branch_color, branch[:category].filter_value)
        add_flow(flow[:side], index, branch_index, branch[:amount], branch_color, branch_percentage)
      end
    end

    # Money moved into investments, for a family that does not count it as spending
    if invested.positive?
      percentage = share(invested, capacity)
      index = add_node("invested_node", I18n.t("pages.dashboard.cashflow_preview.node_labels.invested"), invested, percentage, IncomeStatement::Sankey::INVESTED_COLOR)
      add_link(center, index, invested, IncomeStatement::Sankey::INVESTED_COLOR, percentage)
    end

    net = income - spending - invested
    if net.positive?
      percentage = share(net, income)
      index = add_node("surplus_node", "Surplus", net, percentage, SUCCESS_COLOR)
      add_link(center, index, net, SUCCESS_COLOR, percentage)
    elsif net.negative?
      percentage = share(net.abs, capacity)
      index = add_node("deficit_node", I18n.t("pages.dashboard.cashflow_preview.node_labels.deficit"), net.abs, percentage, DESTRUCTIVE_COLOR)
      add_link(index, center, net.abs, DESTRUCTIVE_COLOR, percentage)
    end

    { nodes: @nodes, links: @links, currency_symbol: Money::Currency.new(@statement.family.currency).symbol }
  end

  # Rounds amounts to cents so that they add up to their total rounded once
  # (largest remainder): each is rounded down, then the cents still missing
  # go one each to the amounts that lost the most (or, when the total needs
  # fewer, come off those that lost the least). Every amount ends within a
  # cent of its exact value. Signed amounts work the same way.
  def self.to_cents(amounts, total)
    cents = amounts.map { |amount| (amount * 100).floor }
    missing = (total.to_d * 100).round - cents.sum
    return cents.map { |cent| cent.to_d / 100 } if missing.zero? || amounts.empty?

    order = amounts.each_index.sort_by { |i| [ -(amounts[i] * 100 - cents[i]), i ] }
    order = order.reverse if missing.negative?
    missing.abs.times { |n| cents[order[n % order.size]] += missing <=> 0 }
    cents.map { |cent| cent.to_d / 100 }
  end

  private
    def netting = IncomeStatement::CategoryNetting

    # The flows beside Cash Flow, and the amount invested, in cents. The flows
    # and invested amount are rounded together against the period's exact net,
    # so Surplus or Deficit is that net rounded once; each category's branches
    # are then rounded against the category's own rounded value.
    def rounded_flows
      flows = netting.new(@statement, period: @period).groups.flat_map { |group| flows_for(group) }
      invested = @statement.invested_total(period: @period).amount.to_d
      signed = flows.map { |flow| flow[:side] == :income ? flow[:value] : -flow[:value] } + [ -invested ]
      rounded = self.class.to_cents(signed, signed.sum).map(&:abs)

      flows = flows.zip(rounded).filter_map do |flow, value|
        next if value.zero?
        amounts = self.class.to_cents(flow[:branches].map { |branch| branch[:amount] }, value)
        branches = flow[:branches].zip(amounts).filter_map { |branch, amount| branch.merge(amount: amount) unless amount.zero? }
        flow.merge(value: value, branches: branches.any? { |branch| !branch[:own] } ? branches : [])
      end
      [ flows, rounded.last ]
    end

    # The nodes one category group adds beside Cash Flow, at exact amounts.
    def flows_for(group)
      category = group[:category]
      net = group[:direct] + group[:children].sum { |child| child[:net] }
      side = net.negative? ? :income : :expense
      other_side = side == :income ? :expense : :income
      node_key = category.id || category.name

      flows = [ { side: side, id: "#{side}_#{node_key}", name: category.name, category: category,
                  value: netting.side_total(group, side), branches: netting.side_branches(group, side) } ]
      netting.side_children(group, other_side).each do |child|
        flows << { side: other_side, id: child[:id], name: child[:name], category: child[:category], value: child[:amount], branches: [] }
      end
      flows << { side: other_side, id: "#{other_side}_#{node_key}", name: category.name, category: category,
                 value: netting.side_amount(group[:direct], other_side), branches: [] }
      flows.reject { |flow| flow[:value].zero? }
    end

    def add_node(id, name, value, percentage, color, filter_value = nil)
      @node_indices[id] ||= begin
        @nodes << { id: id, name: name, filter_value: filter_value, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
        @nodes.size - 1
      end
    end

    def add_link(source, target, value, color, percentage)
      @links << { source: source, target: target, value: value.to_f, color: color, percentage: percentage.to_f }
    end

    # Income runs toward Cash Flow and spending away from it; inner is the
    # end nearer Cash Flow.
    def add_flow(side, inner, outer, value, color, percentage)
      source, target = side == :income ? [ outer, inner ] : [ inner, outer ]
      add_link(source, target, value, color, percentage)
    end

    def share(value, total)
      total.zero? ? 0 : (value / total * 100).round(1)
    end
end
