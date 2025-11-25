class CashflowStatement::SankeyBuilder
  attr_reader :cashflow_statement, :currency_symbol, :options

  # Options:
  #   include_investing: true/false - whether to include investment activities
  #   include_financing: true/false - whether to include financing activities (loan/cc payments)
  def initialize(cashflow_statement, currency_symbol:, **options)
    @cashflow_statement = cashflow_statement
    @currency_symbol = currency_symbol
    @options = {
      include_investing: true,
      include_financing: true
    }.merge(options)
  end

  def build
    @nodes = []
    @links = []
    @node_indices = {}

    build_cash_flow_node
    build_operating_inflows
    build_investing_inflows if include_investing?
    build_operating_outflows
    build_investing_outflows if include_investing?
    build_financing_outflows if include_financing?
    build_surplus_or_deficit

    { nodes: @nodes, links: @links, currency_symbol: currency_symbol }
  end

  private
    def include_investing?
      options[:include_investing]
    end

    def include_financing?
      options[:include_financing]
    end

    def operating
      @operating ||= cashflow_statement.operating_activities
    end

    def investing
      @investing ||= cashflow_statement.investing_activities
    end

    def financing
      @financing ||= cashflow_statement.financing_activities
    end

    # Calculate totals based on what activities are being shown
    def total_inflows
      @total_inflows ||= begin
        total = operating.inflows.to_f
        total += investing.inflows.to_f if include_investing?
        total += financing.inflows.to_f if include_financing?
        total.round(2)
      end
    end

    def total_outflows
      @total_outflows ||= begin
        total = operating.outflows.to_f
        total += investing.outflows.to_f if include_investing?
        total += financing.outflows.to_f if include_financing?
        total.round(2)
      end
    end

    def net_cash_flow
      @net_cash_flow ||= (total_inflows - total_outflows).round(2)
    end

    def cash_flow_idx
      @cash_flow_idx ||= add_node("cash_flow_node", "Cash Flow", total_inflows, 100.0, "var(--color-success)")
    end

    def build_cash_flow_node
      cash_flow_idx # Initialize the cash flow node
    end

    def build_operating_inflows
      # Income by category
      operating.income_by_category.each do |ct|
        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total_inflows.zero? ? 0 : (val / total_inflows * 100).round(1)
        color = ct.category.color.presence || Category::COLORS.sample

        idx = add_node(
          "income_#{ct.category.id || 'uncategorized'}",
          ct.category.name,
          val,
          percentage,
          color
        )

        @links << {
          source: idx,
          target: cash_flow_idx,
          value: val,
          color: color,
          percentage: percentage
        }
      end
    end

    def build_investing_inflows
      # Investment liquidations (selling investments = cash inflow)
      withdrawals = investing.inflows.to_f.round(2)
      return unless withdrawals.positive?

      percentage = total_inflows.zero? ? 0 : (withdrawals / total_inflows * 100).round(1)

      idx = add_node(
        "investment_liquidations",
        "Investment Liquidations",
        withdrawals,
        percentage,
        Category::INVESTMENT_COLOR
      )

      @links << {
        source: idx,
        target: cash_flow_idx,
        value: withdrawals,
        color: Category::INVESTMENT_COLOR,
        percentage: percentage
      }
    end

    def build_operating_outflows
      # Expenses by category
      operating.expenses_by_category.each do |ct|
        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total_outflows.zero? ? 0 : (val / total_outflows * 100).round(1)
        color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR

        idx = add_node(
          "expense_#{ct.category.id || 'uncategorized'}",
          ct.category.name,
          val,
          percentage,
          color
        )

        @links << {
          source: cash_flow_idx,
          target: idx,
          value: val,
          color: color,
          percentage: percentage
        }
      end
    end

    def build_investing_outflows
      # Investment contributions (buying investments = cash outflow)
      contributions = investing.outflows.to_f.round(2)
      return unless contributions.positive?

      percentage = total_outflows.zero? ? 0 : (contributions / total_outflows * 100).round(1)

      idx = add_node(
        "investment_contributions",
        "Investment Contributions",
        contributions,
        percentage,
        Category::INVESTMENT_COLOR
      )

      @links << {
        source: cash_flow_idx,
        target: idx,
        value: contributions,
        color: Category::INVESTMENT_COLOR,
        percentage: percentage
      }
    end

    def build_financing_outflows
      # Loan payments
      loan_payments = financing.loan_payments.to_f.round(2)
      if loan_payments.positive?
        percentage = total_outflows.zero? ? 0 : (loan_payments / total_outflows * 100).round(1)

        idx = add_node(
          "loan_payments",
          "Loan Payments",
          loan_payments,
          percentage,
          "#7c3aed" # Purple for financing
        )

        @links << {
          source: cash_flow_idx,
          target: idx,
          value: loan_payments,
          color: "#7c3aed",
          percentage: percentage
        }
      end

      # Credit card payments
      cc_payments = financing.cc_payments.to_f.round(2)
      return unless cc_payments.positive?

      percentage = total_outflows.zero? ? 0 : (cc_payments / total_outflows * 100).round(1)

      idx = add_node(
        "cc_payments",
        "Credit Card Payments",
        cc_payments,
        percentage,
        "#7c3aed"
      )

      @links << {
        source: cash_flow_idx,
        target: idx,
        value: cc_payments,
        color: "#7c3aed",
        percentage: percentage
      }
    end

    def build_surplus_or_deficit
      if net_cash_flow.positive?
        percentage = total_inflows.zero? ? 0 : (net_cash_flow / total_inflows * 100).round(1)

        idx = add_node("surplus_node", "Surplus", net_cash_flow, percentage, "var(--color-success)")

        @links << {
          source: cash_flow_idx,
          target: idx,
          value: net_cash_flow,
          color: "var(--color-success)",
          percentage: percentage
        }
      elsif net_cash_flow.negative?
        # Deficit - show as a source flowing into cash flow
        deficit = net_cash_flow.abs
        percentage = total_outflows.zero? ? 0 : (deficit / total_outflows * 100).round(1)

        idx = add_node("deficit_node", "Deficit", deficit, percentage, "var(--color-destructive)")

        @links << {
          source: idx,
          target: cash_flow_idx,
          value: deficit,
          color: "var(--color-destructive)",
          percentage: percentage
        }
      end
    end

    def add_node(unique_key, display_name, value, percentage, color)
      @node_indices[unique_key] ||= begin
        @nodes << { name: display_name, value: value, percentage: percentage, color: color }
        @nodes.size - 1
      end
    end
end
