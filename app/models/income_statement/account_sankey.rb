# Cash-flow Sankey grouped by account: income categories -> accounts -> expense
# categories. Each account's categories are netted with IncomeStatement::
# CategoryNetting, scoped to that account. What an account takes in beyond what
# it spends flows on to Surplus; an account that spends more than it takes in
# (a credit card paid off by transfer, savings being drawn down) is fed from
# Deficit. Transfers between accounts are neither income nor spending, but where
# an account in surplus paid one in deficit, that transfer is drawn between the
# two accounts (see #transfer_funding), so a card paid off from a current
# account shows where its money came from instead of a Surplus on one side and
# an equal Deficit on the other.
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
      funding = transfer_funding(flows)
      flows.each { |flow| add_account(flow, income, spending, capacity, subcategory_flows, funding) }
      add_transfers(funding, capacity)
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

    def add_account(flow, income, spending, capacity, subcategory_flows, funding)
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

      id = account.id
      net = flow[:income] - flow[:spending] +
        funding.sum { |(_, to), value| to == id ? value : 0 } -
        funding.sum { |(from, _), value| from == id ? value : 0 }
      return if net.zero?

      kind = net.positive? ? :surplus : :deficit
      balance = node("#{kind}_node", kind.to_s.capitalize, kind)
      balance[:value] += net.abs
      balance[:percentage] = percentage(balance[:value], capacity)
      link(*(net.positive? ? [ center, balance ] : [ balance, center ]), net.abs, percentage(net.abs, capacity))
    end

    # How much of each deficit account's shortfall was paid by a surplus
    # account, as { [from_id, to_id] => amount }. Uses the period's confirmed
    # transfers (funds movements and card payments) between the accounts in
    # the graph, netted per pair, largest first. Each amount is capped by what
    # the payer has left over and what the payee still needs, so every pound
    # drawn takes the same off Surplus and Deficit (the net is unchanged) and
    # links only run from surplus to deficit accounts, which keeps the graph
    # acyclic.
    def transfer_funding(flows)
      balance = flows.to_h { |flow| [ flow[:account].id, flow[:income] - flow[:spending] ] }
      surplus = balance.select { |_, net| net.positive? }
      deficit = balance.select { |_, net| net.negative? }.transform_values(&:abs)
      return {} if surplus.empty? || deficit.empty?

      moved = Hash.new(0.to_d)
      transfers_between(balance.keys).each do |from, to, amount|
        moved[[ from, to ]] += amount
        moved[[ to, from ]] -= amount
      end

      moved.select { |(from, to), amount| amount.positive? && surplus.key?(from) && deficit.key?(to) }
        .sort_by { |_, amount| -amount }
        .each_with_object({}) do |((from, to), amount), funding|
          value = [ amount, surplus[from], deficit[to] ].min
          next unless value.positive?

          funding[[ from, to ]] = value
          surplus[from] -= value
          deficit[to] -= value
        end
    end

    # [from_account_id, to_account_id, amount in the family currency] for each
    # confirmed transfer in the period between two of the given accounts.
    def transfers_between(account_ids)
      currency = @statement.family.currency
      outflows = Transaction.joins(:entry).where(kind: %w[funds_movement cc_payment],
        entries: { account_id: account_ids, date: @period.start_date..@period.end_date, excluded: false })
      inflows = Transaction.joins(:entry).where(entries: { account_id: account_ids })

      Transfer.confirmed
        .where(outflow_transaction_id: outflows.select(:id), inflow_transaction_id: inflows.select(:id))
        .includes(outflow_transaction: :entry, inflow_transaction: :entry)
        .filter_map do |transfer|
          outflow = transfer.outflow_transaction.entry
          amount = outflow.amount_money.abs.exchange_to(currency, date: outflow.date).amount.to_d
          [ outflow.account_id, transfer.inflow_transaction.entry.account_id, amount ]
        rescue Money::ConversionError
          nil
        end
    end

    def add_transfers(funding, capacity)
      funding.each do |(from, to), value|
        link(@node_index.fetch("account_#{from}"), @node_index.fetch("account_#{to}"), value, percentage(value, capacity))
      end
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
