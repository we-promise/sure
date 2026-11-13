class CreditCard < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "credit_card"

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  StatementSummary = Data.define(
    :balance, :remaining, :charges, :credits, :accrued,
    :due_date, :last_due_date, :next_close, :status, :scheduled_payment,
    :estimated_interest, :monthly_rate
  )
  ScheduledPayment = Data.define(:payment, :due_date)

  validates :statement_close_day, :due_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true

  class << self
    def supports_iban?
      true
    end

    def color
      "#F13636"
    end

    def icon
      "credit-card"
    end

    def classification
      "liability"
    end

    # The outstanding debt on a card whose provider reports the remaining
    # available credit instead of the balance owed. nil when there is no
    # positive limit, because the debt is then unknown. An overpaid card
    # reports more than its limit: clamp_overpayment turns that into zero
    # debt, otherwise it stays a negative (credit) balance.
    def debt_from_available_credit(credit_limit:, available_credit:, clamp_overpayment:)
      return nil unless credit_limit&.positive?

      debt = credit_limit - available_credit
      clamp_overpayment ? [ debt, 0 ].max : debt
    end
  end

  def available_credit_money
    available_credit ? Money.new(available_credit, account.currency) : nil
  end

  def minimum_payment_money
    minimum_payment ? Money.new(minimum_payment, account.currency) : nil
  end

  def annual_fee_money
    annual_fee ? Money.new(annual_fee, account.currency) : nil
  end

  def statement_cycle_configured?
    statement_close_day.present? && account.present?
  end

  def last_statement_close_date(as_of: Date.current)
    return nil unless statement_cycle_configured?

    close = day_of_month_in(as_of, statement_close_day)
    return close if close <= as_of

    day_of_month_in(as_of.prev_month, statement_close_day)
  end

  def previous_statement_close_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    day_of_month_in(last_close.prev_month, statement_close_day)
  end

  def next_statement_close_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    day_of_month_in(last_close.next_month, statement_close_day)
  end

  def payment_due_date_for(close_date)
    return nil if close_date.nil? || due_day.blank?

    due = day_of_month_in(close_date, due_day)
    due = day_of_month_in(close_date.next_month, due_day) if statement_close_day.present? && due_day < statement_close_day

    due
  end

  def next_payment_due_date(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    due = payment_due_date_for(last_close)
    return nil if due.nil?

    # Give way only once the statement is paid; an unpaid bill stays overdue.
    due = payment_due_date_for(next_statement_close_date(as_of: as_of)) if due < as_of && statement_settled?(as_of: as_of)

    due
  end

  def days_until_due(as_of: Date.current)
    due = next_payment_due_date(as_of: as_of)
    return nil if due.nil?

    (due - as_of).to_i
  end

  def last_statement_balance_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    sum_entries_in(..last_close)
  end

  def accrued_since_last_close_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    sum_entries_in((last_close + 1)..as_of)
  end

  # One read of the statement cycle for the Overview tab. The view needs the
  # closed statement, what has happened since, and whether the bill is settled;
  # building them together keeps those figures on one `as_of` and avoids
  # re-querying the same entries for each line.
  def statement_summary(as_of: Date.current, viewer:)
    return nil unless statement_cycle_configured?

    last_close = last_statement_close_date(as_of: as_of)
    balance = last_statement_balance_money(as_of: as_of)
    window = (last_close + 1)..as_of
    totals = cycle_totals(window)
    charges = totals&.dig(:charges)
    credits = totals&.dig(:credits)
    accrued = totals&.dig(:accrued)
    remaining = statement_remaining(balance, credits)
    last_due_date = payment_due_date_for(last_close)

    StatementSummary.new(
      balance: balance,
      remaining: remaining,
      charges: charges,
      credits: credits,
      accrued: accrued,
      due_date: statement_due_date(last_due_date, remaining, as_of),
      last_due_date: last_due_date,
      next_close: next_statement_close_date(as_of: as_of),
      status: statement_status(balance: balance, remaining: remaining, due_date: last_due_date, as_of: as_of),
      scheduled_payment: next_scheduled_payment(as_of: as_of, viewer: viewer),
      estimated_interest: estimated_monthly_interest_money(remaining),
      monthly_rate: monthly_rate
    )
  end

  def minimum_payment_shortfall?(as_of: Date.current)
    minimum = minimum_payment_money
    balance = last_statement_balance_money(as_of: as_of)
    return false if minimum.nil? || balance.nil?

    balance > minimum
  end

  private
    def cycle_totals(window)
      summable = summable_entries(window)
      return nil if summable.nil?

      charges = BigDecimal(0)
      credits = BigDecimal(0)
      summable.pluck(:amount).each do |amount|
        if amount.positive?
          charges += amount
        elsif amount.negative?
          credits += amount
        end
      end

      {
        charges: Money.new(charges, account.currency),
        credits: Money.new(credits, account.currency),
        accrued: Money.new(charges + credits, account.currency)
      }
    end

    def sum_entries_in(window, amount_sign: nil)
      summable = summable_entries(window)
      return nil if summable.nil?

      amount_scope = case amount_sign
      when :positive then summable.where("amount > 0")
      when :negative then summable.where("amount < 0")
      else summable
      end

      Money.new(amount_scope.sum(:amount), account.currency)
    end

    def summable_entries(window)
      scoped = account.entries.excluding_pending.excluding_split_parents.where(date: window)

      # An entry we cannot add up -- booked in another currency, or in none at
      # all -- makes the total unknown rather than smaller. `where.not(currency:)`
      # compiles to `!= AND IS NOT NULL`, so it never matches a NULL and the
      # guard would sit there dead for the exact case it was written for. Compare
      # the counts instead: anything outside the account's own currency refuses
      # the whole statement, because quoting only the part that did match would
      # report a partial figure as if it were the whole.
      summable = scoped.where(currency: account.currency)
      return nil if summable.count != scoped.count

      summable
    end

    def statement_remaining(balance, credits)
      return nil if balance.nil? || credits.nil?
      return Money.new(0, balance.currency) unless balance.positive?

      Money.new([ balance.amount + credits.amount, 0 ].max, balance.currency)
    end

    # Once the closed bill is settled, its due date is no longer the next one
    # the cardholder has to meet. Keep an unpaid bill's date in place even when
    # it has passed, so the Overview still says it is overdue.
    def statement_due_date(last_due_date, remaining, as_of)
      return last_due_date if last_due_date.nil? || remaining.nil?
      return last_due_date unless remaining.zero? && last_due_date < as_of

      payment_due_date_for(next_statement_close_date(as_of: as_of))
    end

    def statement_status(balance:, remaining:, due_date:, as_of:)
      return nil if balance.nil? || remaining.nil?
      return :no_balance unless balance.positive?
      return :paid if remaining.zero?
      return :overdue if due_date.present? && due_date < as_of
      return :partial if remaining.amount < balance.amount

      :unpaid
    end

    # Use the earliest open occurrence, even when its date has passed: an
    # unpaid scheduled payment is exactly the one the cardholder needs to see.
    # The cached next_expected_date can stay stale after a manual payment, so
    # fall back to it only when the series has no occurrence yet.
    def next_scheduled_payment(as_of:, viewer:)
      RecurringTransaction
        .accessible_by(viewer)
        .where(destination_account_id: account.id)
        .active
        .includes(:recurring_occurrences)
        .filter_map do |payment|
          due_date = next_open_due_date(payment, as_of)
          ScheduledPayment.new(payment: payment, due_date: due_date) if due_date
        end
        .min_by(&:due_date)
    end

    def next_open_due_date(payment, as_of)
      occurrence = payment.recurring_occurrences.select(&:scheduled?).min_by(&:due_on)
      return occurrence.effective_due_on if occurrence

      payment.next_expected_date if payment.next_expected_date >= as_of
    end

    def monthly_rate
      apr / 12 if apr.present?
    end

    def estimated_monthly_interest_money(balance)
      return nil if apr.blank? || balance.nil?
      return Money.new(0, account.currency) unless balance.positive?

      Money.new(
        (balance.amount * apr / 100 / 12).round(balance.currency.default_precision || 2),
        account.currency
      )
    end

    def statement_settled?(as_of: Date.current)
      balance = last_statement_balance_money(as_of: as_of)
      return false if balance.nil?
      return true unless balance.positive?

      last_close = last_statement_close_date(as_of: as_of)
      credits = sum_entries_in((last_close + 1)..as_of, amount_sign: :negative)
      return false if credits.nil?

      credits.amount.abs >= balance.amount
    end

    def day_of_month_in(base_date, day)
      Date.new(base_date.year, base_date.month, [ day, base_date.end_of_month.day ].min)
    end
end
