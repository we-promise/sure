# Credits interest to a fixed-return account (a savings account, Tagesgeldkonto,
# term deposit — anything that pays a known rate and isn't covered by a data
# provider).
#
# Interest accrues on the account's average daily balance at actual/365 and is
# credited as a real income transaction on each period end, so it shows up in
# the balance, the income statement and the cash-flow views exactly like a
# posting from a linked bank would. Because each posting raises the balance,
# subsequent periods compound on their own.
#
# Postings are idempotent: each one is keyed by its posting date, so re-running
# a sync never double-credits a period.
class Depository::FixedReturnPoster
  SOURCE = "fixed_return".freeze

  MONTHS_PER_PERIOD = {
    "monthly" => 1,
    "quarterly" => 3,
    "annually" => 12
  }.freeze

  DAY_COUNT_BASIS = BigDecimal(365)

  attr_reader :account

  def initialize(account)
    @account = account
  end

  # Creates any interest entries that have come due since the last posting.
  # Returns the entries it created.
  def post_due_interest!
    return [] unless depository&.fixed_return?

    due_periods.filter_map { |period_start, posting_date| post_period(period_start, posting_date) }
  end

  private
    def depository
      account.accountable if account.accountable_type == "Depository"
    end

    def months_per_period
      MONTHS_PER_PERIOD.fetch(depository.fixed_return_frequency)
    end

    # [period_start, posting_date] pairs for every period that has fully
    # elapsed and has not been credited yet. period_start is exclusive,
    # posting_date is the day interest lands (and the last day accrued).
    def due_periods
      periods = []
      posted_on = already_posted_dates
      index = 0

      loop do
        period_start = period_boundary(index)
        posting_date = period_boundary(index += 1)
        break if posting_date > Date.current

        periods << [ period_start, posting_date ] unless posted_on.include?(posting_date)
      end

      periods
    end

    # Boundaries are measured from the original start date rather than chained
    # off the previous posting, so a short month doesn't drag every later
    # posting earlier: a Jan 31 start pays Feb 28, Mar 31, Apr 30 — not Feb 28,
    # Mar 28, Apr 28.
    def period_boundary(index)
      depository.fixed_return_start_date >> (index * months_per_period)
    end

    def already_posted_dates
      account.entries.where(source: SOURCE).pluck(:external_id).compact.map { |id| Date.parse(id) }.to_set
    end

    def post_period(period_start, posting_date)
      interest = interest_for(period_start, posting_date)
      return nil if interest.zero?

      entry = account.entries.create!(
        date: posting_date,
        name: I18n.t("depositories.fixed_return.interest_entry_name", default: "Interest"),
        amount: -interest,
        currency: account.currency,
        source: SOURCE,
        external_id: posting_date.iso8601,
        entryable: Transaction.new
      )

      Rails.logger.info("Posted fixed-return interest #{interest} to account #{account.id} on #{posting_date}")

      entry
    end

    # Average daily balance over (period_start, posting_date], at actual/365.
    def interest_for(period_start, posting_date)
      accrual_dates = (period_start + 1)..posting_date
      balances = balances_by_date(accrual_dates)
      return BigDecimal(0) if balances.empty?

      average_balance = balances.sum(BigDecimal(0)) / balances.size
      return BigDecimal(0) if average_balance <= 0

      days = accrual_dates.count
      rate = BigDecimal(depository.fixed_return_rate.to_s) / 100

      (average_balance * rate * days / DAY_COUNT_BASIS).round(currency_precision)
    end

    # Materialized end-of-day balances for the range. Days with no balance row
    # (before the account existed, or not yet materialized) are skipped rather
    # than counted as zero, so a partially materialized history understates the
    # period instead of wiping it out.
    def balances_by_date(dates)
      account.balances
             .where(date: dates, currency: account.currency)
             .pluck(:balance)
    end

    def currency_precision
      @currency_precision ||= Money::Currency.new(account.currency).default_precision || 2
    end
end
