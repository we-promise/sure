class CashflowStatement
  include Monetizable

  attr_reader :family, :period

  def initialize(family, period: Period.current_month)
    @family = family
    @period = period
  end

  # Operating Activities: Regular income/expenses (day-to-day transactions)
  # Excludes: transfers, investments, loan/cc payments
  def operating_activities
    @operating_activities ||= OperatingActivities.new(family, period: period)
  end

  # Investing Activities: Buy/sell trades, investment income
  def investing_activities
    @investing_activities ||= InvestingActivities.new(family, period: period)
  end

  # Financing Activities: Loan payments, credit card payments
  def financing_activities
    @financing_activities ||= FinancingActivities.new(family, period: period)
  end

  # Net cash flow across all activities
  def net_cash_flow
    operating_activities.net + investing_activities.net + financing_activities.net
  end

  def net_cash_flow_money
    Money.new(net_cash_flow, family.currency)
  end

  # Total inflows across all activities
  def total_inflows
    operating_activities.inflows + investing_activities.inflows + financing_activities.inflows
  end

  def total_inflows_money
    Money.new(total_inflows, family.currency)
  end

  # Total outflows across all activities
  def total_outflows
    operating_activities.outflows + investing_activities.outflows + financing_activities.outflows
  end

  def total_outflows_money
    Money.new(total_outflows, family.currency)
  end

  # Summary for views
  def summary
    Summary.new(
      operating: operating_activities.summary,
      investing: investing_activities.summary,
      financing: financing_activities.summary,
      net_cash_flow: net_cash_flow_money,
      total_inflows: total_inflows_money,
      total_outflows: total_outflows_money
    )
  end

  # For sankey chart - returns all flows grouped by activity type
  # Options:
  #   include_investing: true/false - whether to include investment activities
  #   include_financing: true/false - whether to include financing activities
  def sankey_data(currency_symbol:, **options)
    SankeyBuilder.new(self, currency_symbol: currency_symbol, **options).build
  end

  private
    Summary = Data.define(:operating, :investing, :financing, :net_cash_flow, :total_inflows, :total_outflows)

    def monetizable_currency
      family.currency
    end
end
