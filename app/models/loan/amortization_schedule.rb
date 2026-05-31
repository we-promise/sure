class Loan::AmortizationSchedule
  Row = Struct.new(
    :period_number,
    :due_date,
    :opening_principal,
    :interest,
    :scheduled_principal,
    :scheduled_payment,
    :extra_principal,
    :closing_principal,
    keyword_init: true
  )

  def initialize(loan, as_of: Date.current, extra_principal_by_period: {})
    @loan = loan
    @as_of = as_of
    @extra_principal_by_period = extra_principal_by_period.transform_keys(&:to_i)
  end

  def rows
    @rows ||= build_rows
  end

  def paid_rows
    rows.select { |row| row.due_date <= as_of }
  end

  def upcoming_rows(limit: 3)
    rows.select { |row| row.due_date > as_of }.first(limit)
  end

  def scheduled_balance
    row = rows.select { |schedule_row| schedule_row.due_date <= as_of }.last
    row&.closing_principal || principal
  end

  def balance_variance
    return nil unless loan.account

    loan.account.balance.to_d - scheduled_balance
  end

  def total_interest
    rows.sum(BigDecimal("0")) { |row| row.interest }
  end

  def payoff_date
    rows.last&.due_date
  end

  def current_rate_period(date = as_of)
    rate_period_for(date)
  end

  def current_scheduled_payment(date = as_of)
    target = rows.find { |row| row.due_date >= date } || rows.last
    target&.scheduled_payment
  end

  def remaining_periods
    rows.count { |row| row.due_date > as_of }
  end

  private
    attr_reader :loan, :as_of, :extra_principal_by_period

    def build_rows
      return [] unless loan.annuity_enabled?
      return [] if principal <= 0 || loan.term_months.to_i <= 0 || rate_periods.empty?

      remaining_principal = principal
      rows = []
      current_period = nil
      current_payment = nil

      1.upto(loan.term_months.to_i) do |period_number|
        break if remaining_principal <= 0

        due_date = loan.started_on.advance(months: period_number)
        rate_period = rate_period_for(due_date)
        if rate_period != current_period
          current_period = rate_period
          current_payment = payment_for(
            principal: remaining_principal,
            annual_rate: current_period.annual_rate.to_d,
            remaining_periods: loan.term_months.to_i - period_number + 1,
            override: current_period.payment_amount
          )
        end

        monthly_rate = monthly_rate_for(current_period.annual_rate)
        interest = round_money(remaining_principal * monthly_rate)
        scheduled_payment = round_money(current_payment)
        scheduled_principal = round_money(scheduled_payment - interest)
        scheduled_principal = BigDecimal("0") if scheduled_principal.negative?

        extra_principal = round_money(extra_principal_by_period.fetch(period_number, 0).to_d)
        principal_payment = scheduled_principal + extra_principal

        if period_number == loan.term_months.to_i || principal_payment >= remaining_principal
          scheduled_principal = remaining_principal
          extra_principal = BigDecimal("0")
          scheduled_payment = round_money(interest + scheduled_principal)
        end

        closing_principal = round_money(remaining_principal - scheduled_principal - extra_principal)
        closing_principal = BigDecimal("0") if closing_principal.abs < BigDecimal("0.01")

        rows << Row.new(
          period_number: period_number,
          due_date: due_date,
          opening_principal: round_money(remaining_principal),
          interest: interest,
          scheduled_principal: scheduled_principal,
          scheduled_payment: scheduled_payment,
          extra_principal: extra_principal,
          closing_principal: closing_principal
        )

        remaining_principal = closing_principal
      end

      rows
    end

    def payment_for(principal:, annual_rate:, remaining_periods:, override:)
      return override.to_d if override.present?

      monthly_rate = monthly_rate_for(annual_rate)
      return principal / remaining_periods if monthly_rate.zero?

      factor = (1 + monthly_rate)**remaining_periods
      (principal * monthly_rate * factor) / (factor - 1)
    end

    def monthly_rate_for(annual_rate)
      annual_rate.to_d / 100 / 12
    end

    def rate_period_for(date)
      rate_periods.select { |period| period.starts_on <= date }.last || rate_periods.first
    end

    def rate_periods
      @rate_periods ||= loan.loan_rate_periods
        .reject(&:marked_for_destruction?)
        .sort_by(&:starts_on)
    end

    def principal
      @principal ||= loan.initial_balance.presence&.to_d || loan.original_balance.amount.to_d
    end

    def round_money(value)
      value.to_d.round(2)
    end
end
