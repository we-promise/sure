class CreditCard < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "credit_card"

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  validates :statement_close_day, :due_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true

  class << self
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

  def minimum_payment_shortfall?(as_of: Date.current)
    minimum = minimum_payment_money
    balance = last_statement_balance_money(as_of: as_of)
    return false if minimum.nil? || balance.nil?

    balance > minimum
  end

  private
    def sum_entries_in(window)
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

      Money.new(summable.sum(:amount), account.currency)
    end

    def statement_settled?(as_of: Date.current)
      balance = last_statement_balance_money(as_of: as_of)
      return false if balance.nil?
      return true unless balance.positive?

      last_close = last_statement_close_date(as_of: as_of)
      payments = account.entries.excluding_pending.excluding_split_parents
        .where(date: (last_close + 1)..as_of, currency: account.currency)
        .where("amount < 0")
        .sum(:amount).abs

      payments >= balance.amount
    end

    def day_of_month_in(base_date, day)
      Date.new(base_date.year, base_date.month, [ day, base_date.end_of_month.day ].min)
    end
end
