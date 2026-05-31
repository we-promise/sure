class Loan::PaymentSplitter
  Split = Struct.new(
    :matched,
    :period_number,
    :due_date,
    :interest,
    :principal,
    :extra_principal,
    :variance,
    :scheduled_payment,
    keyword_init: true
  ) do
    def matched?
      matched
    end
  end

  DEFAULT_DATE_WINDOW = 7

  def initialize(loan, date_window: DEFAULT_DATE_WINDOW)
    @loan = loan
    @date_window = date_window
  end

  def split(payment_date:, amount:, paid_period_numbers: nil)
    paid_period_numbers ||= loan.paid_annuity_period_numbers
    row = nearest_unpaid_row(payment_date, paid_period_numbers.map(&:to_i))
    return unmatched(amount) unless row

    remaining_payment = amount.to_d
    interest = [ remaining_payment, row.interest ].min
    remaining_payment -= interest

    principal = [ remaining_payment, row.scheduled_principal ].min
    remaining_payment -= principal

    extra_principal = [ remaining_payment, BigDecimal("0") ].max
    variance = row.scheduled_payment - amount.to_d
    variance = BigDecimal("0") if variance.negative?

    Split.new(
      matched: true,
      period_number: row.period_number,
      due_date: row.due_date,
      interest: interest,
      principal: principal,
      extra_principal: extra_principal,
      variance: variance,
      scheduled_payment: row.scheduled_payment
    )
  end

  private
    attr_reader :loan, :date_window

    def nearest_unpaid_row(payment_date, paid_period_numbers)
      Loan::AmortizationSchedule.new(loan, as_of: payment_date).rows
        .reject { |row| paid_period_numbers.include?(row.period_number) }
        .select { |row| (row.due_date - payment_date).abs <= date_window.to_i }
        .min_by { |row| (row.due_date - payment_date).abs }
    end

    def unmatched(amount)
      Split.new(
        matched: false,
        period_number: nil,
        due_date: nil,
        interest: BigDecimal("0"),
        principal: BigDecimal("0"),
        extra_principal: BigDecimal("0"),
        variance: amount.to_d,
        scheduled_payment: nil
      )
    end
end
