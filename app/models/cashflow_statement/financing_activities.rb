class CashflowStatement::FinancingActivities
  include Monetizable

  attr_reader :family, :period

  def initialize(family, period:)
    @family = family
    @period = period
  end

  # Inflows: Borrowing money (new loans, credit card spending increases debt)
  # For personal finance, this is less common to track as "inflow"
  # We'll focus on outflows (debt payments)
  def inflows
    @inflows ||= 0 # Could track new debt here if needed
  end

  def inflows_money
    Money.new(inflows, family.currency)
  end

  # Outflows: Loan payments, credit card payments
  def outflows
    @outflows ||= totals[:payments]
  end

  def outflows_money
    Money.new(outflows, family.currency)
  end

  def net
    inflows - outflows
  end

  def net_money
    Money.new(net, family.currency)
  end

  def loan_payments
    @loan_payments ||= totals[:loan_payments]
  end

  def loan_payments_money
    Money.new(loan_payments, family.currency)
  end

  def cc_payments
    @cc_payments ||= totals[:cc_payments]
  end

  def cc_payments_money
    Money.new(cc_payments, family.currency)
  end

  def summary
    Summary.new(
      inflows: inflows_money,
      outflows: outflows_money,
      net: net_money,
      loan_payments: loan_payments_money,
      cc_payments: cc_payments_money
    )
  end

  private
    Summary = Data.define(:inflows, :outflows, :net, :loan_payments, :cc_payments)

    def totals
      @totals ||= begin
        result = ActiveRecord::Base.connection.select_one(totals_query_sql)
        {
          payments: (result["loan_payments"]&.to_d || 0) + (result["cc_payments"]&.to_d || 0),
          loan_payments: result["loan_payments"]&.to_d || 0,
          cc_payments: result["cc_payments"]&.to_d || 0
        }
      end
    end

    def totals_query_sql
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL,
          SELECT
            COALESCE(SUM(CASE WHEN t.kind = 'loan_payment' THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as loan_payments,
            COALESCE(SUM(CASE WHEN t.kind = 'cc_payment' THEN ABS(ae.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as cc_payments
          FROM transactions t
          JOIN entries ae ON ae.entryable_id = t.id AND ae.entryable_type = 'Transaction'
          JOIN accounts a ON a.id = ae.account_id
          LEFT JOIN exchange_rates er ON (
            er.date = ae.date AND
            er.from_currency = ae.currency AND
            er.to_currency = :target_currency
          )
          WHERE a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND ae.excluded = false
            AND ae.date BETWEEN :start_date AND :end_date
            AND t.kind IN ('loan_payment', 'cc_payment')
        SQL
        {
          family_id: family.id,
          target_currency: family.currency,
          start_date: period.start_date,
          end_date: period.end_date
        }
      ])
    end

    def monetizable_currency
      family.currency
    end
end
