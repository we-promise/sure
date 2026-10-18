class CreditCard < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "credit_card"

  SUBTYPES = {
    "credit_card" => { short: "Credit Card", long: "Credit Card" }
  }.freeze

  # A statement cycle is recorded as two days of the month, not as a set of
  # dated statements: a card closes on the same day every month, and the only
  # reason to learn that day is to work out which charges land on which
  # statement. Nothing else about the cycle is stored -- the statement balance
  # is derived from entries every time it is asked for, because a stored
  # figure would be a third source of truth for a number `account.balance`
  # already owns, and on a linked card the two disagree by design (the account
  # balance is the provider's anchor, not the sum of its entries).
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

  # Whether a card has told us when its statements close. The due day alone is
  # not enough: without the close day there is no way to tell which charges
  # belong to which statement, which is the whole point of the cycle.
  def statement_cycle_configured?
    statement_close_day.present? && account.present?
  end

  # The close that has already happened, on or before `as_of`. A card closing
  # on the 25th and read on the 25th has closed today, so this is the close
  # itself rather than last month's -- the boundary being inclusive on the
  # close day is what puts a same-day charge on the statement that just issued.
  def last_statement_close_date(as_of: Date.current)
    return nil unless statement_cycle_configured?

    close = day_of_month_in(as_of, statement_close_day)
    return close if close <= as_of

    day_of_month_in(as_of.prev_month, statement_close_day)
  end

  # The close before that one: the opening edge of the statement that issued
  # on `last_statement_close_date`. Exclusive, because the previous statement
  # already owns its close day.
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

  # When the statement closing on `close_date` has to be paid. A card that
  # closes late in the month and is due early in the next one -- the normal
  # shape -- lands on the next month's due day by that wrap. A due day that
  # falls before the close day wraps forward a month rather than reporting a
  # payment that was already overdue when the statement issued. A due day
  # landing exactly on the close day is left alone: a charge card can be both.
  #
  # Wrap on the configured days, not the clamped dates: a card closing on the
  # 31st and due on the 28th has both clamp to February 28th.
  def payment_due_date_for(close_date)
    return nil if close_date.nil? || due_day.blank?

    due = day_of_month_in(close_date, due_day)
    due = day_of_month_in(close_date.next_month, due_day) if statement_close_day.present? && due_day < statement_close_day

    due
  end

  # The payment a cardholder next has to make: the statement that has already
  # closed and has not been paid for yet.
  #
  # Anchored on the close that has HAPPENED, not the one coming. A card closing
  # on the 10th and due on the 26th, read on the 16th, is due on the 26th of
  # this month -- not the 26th of next month, which is the statement still
  # building and not yet a bill anyone owes.
  #
  # When that due date has itself gone by -- a card closing on the 25th and due
  # on the 5th, read on the 16th -- a payment that has been MADE gives way to
  # the one the card is now building toward.
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

  # What the last statement came to: everything charged less everything paid
  # through its close -- carried debt plus this cycle. Negative is a credit,
  # not a negative bill.
  def last_statement_balance_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    sum_entries_in(..last_close)
  end

  # Everything charged since that statement closed: the in-progress statement.
  # This, not the balance above, is what the next payment will be made on.
  def accrued_since_last_close_money(as_of: Date.current)
    last_close = last_statement_close_date(as_of: as_of)
    return nil if last_close.nil?

    sum_entries_in((last_close + 1)..as_of)
  end

  # Whether the last statement came to more than the minimum payment. A card
  # carrying a minimum payment but no last statement cannot be short of it,
  # and a zero minimum payment means no minimum was set rather than one of nil.
  def minimum_payment_shortfall?(as_of: Date.current)
    minimum = minimum_payment_money
    balance = last_statement_balance_money(as_of: as_of)
    return false if minimum.nil? || balance.nil?

    balance > minimum
  end

  private
    # Totals a span of entries in the card's own currency, or refuses.
    #
    # Same entry selection as the balance engine
    # (Balance::SyncCache#converted_entries), so a statement balance and the
    # account balance come out of one book rather than two. Excluded entries
    # are counted there too: exclusion is a budgeting and categorisation flag,
    # not a claim that the spend never happened.
    #
    # Refusing is the interesting half. A card whose entries are booked in
    # another currency cannot be totalled from the entries alone, because the
    # balance engine converts each one at the rate for its own date. A rate we
    # do not hold is better reported as unknown than guessed, and better still
    # than silently counting only the entries that happened to match.
    def sum_entries_in(window)
      scoped = account.entries.excluding_pending.excluding_split_parents.where(date: window)
      # where.not(currency:) matches no NULLs, so an entry with no currency
      # refuses the total like a foreign one instead of dropping out quietly.
      return nil if scoped.where.not(currency: [ account.currency, nil ]).exists?

      Money.new(scoped.where(currency: account.currency).sum(:amount), account.currency)
    end

    # Whether the last statement has been paid: payments since its close add
    # up to at least what it came to. One that cannot be totalled counts as
    # unpaid.
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

    # `statement_close_day` and `due_day` are days of the month, not dates, so a
    # card closing on the 31st closes on the 30th in November and on the 28th in
    # February. Clamping to the last day of the month is what an issuer does, and
    # it keeps the day-of-month meaning stable across a leap year.
    def day_of_month_in(base_date, day)
      Date.new(base_date.year, base_date.month, [ day, base_date.end_of_month.day ].min)
    end
end
