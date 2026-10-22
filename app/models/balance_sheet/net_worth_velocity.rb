# How fast net worth is moving over a period (velocity, per month) and how that
# pace compares with the period immediately before it (momentum).
#
# Both are read from `BalanceSheet::NetWorthBreakdownSeriesBuilder#breakdown_series`,
# the series the Reports page draws, which already honours the viewer's account
# visibility and is cached per period. Its first and last points are always the
# window's own start and end dates, whatever the interval. Amounts are BigDecimal
# throughout; the series hands them over already rounded to the currency's display
# precision, and `Money#format` is the only rounding applied here.
#
# Cost: each call builds the per-group series as well, which velocity does not
# use, and the dashboard asks for two windows (this period and the one before).
# Both are cached.
#
# Velocity and momentum are withheld (nil) rather than guessed when the family's
# history does not cover the whole window they compare. Net worth reads zero
# before the first entry, so a window that starts earlier than the data would
# look like a flat stretch, or like growth from nothing when an account is added
# mid-period. Neither is a pace worth reporting.
class BalanceSheet::NetWorthVelocity
  DAYS_PER_MONTH = BigDecimal("365.2425") / 12

  attr_reader :period

  def initialize(balance_sheet, period:)
    @balance_sheet = balance_sheet
    @period = period
  end

  # Net worth change per month over `period`, or nil.
  def velocity
    return @velocity if defined?(@velocity)

    @velocity = monthly_pace(period)
  end

  # Velocity minus the prior period's velocity, or nil when either is unknown.
  def momentum
    return @momentum if defined?(@momentum)

    prior_velocity = monthly_pace(prior_period)
    @momentum = velocity && prior_velocity ? velocity - prior_velocity : nil
  end

  # The window of the same length ending the day before `period` starts.
  def prior_period
    @prior_period ||= Period.custom(start_date: period.start_date - period.days, end_date: period.start_date - 1)
  end

  private
    attr_reader :balance_sheet

    def monthly_pace(window)
      return nil unless history_covers?(window)

      points = breakdown_builder.breakdown_series(period: window)[:values]
      return nil if points.size < 2

      first, last = points.first, points.last
      days = (last[:date] - first[:date]).to_i
      return nil unless days.positive?

      per_day = (amount_of(last[:value]) - amount_of(first[:value])) / days
      Money.new(per_day * DAYS_PER_MONTH, balance_sheet.currency)
    end

    def breakdown_builder
      @breakdown_builder ||= BalanceSheet::NetWorthBreakdownSeriesBuilder.new(balance_sheet.family, user: balance_sheet.user)
    end

    def amount_of(value)
      (value.respond_to?(:amount) ? value.amount : value).to_d
    end

    # Every account that has history by the window's end must have it from the
    # window's start. One account with a long history must not vouch for another
    # that opens inside the window: its balance arrives from nothing, and the
    # series counts that as growth. An account that opens after the window ends
    # reads zero throughout it, so it does not hold that window back.
    def history_covers?(window)
      starts = account_start_dates.values.select { |date| date <= window.end_date }
      starts.any? && starts.max <= window.start_date
    end

    # The first date each account has history, as Account#history_start_date
    # reads it for an unlinked account: its first entry or its first balance,
    # whichever is earlier. The series is drawn from Balance rows, so an account
    # with balances but no entries counts. Accounts with neither add nothing to
    # the series and are left out.
    #
    # Pending transactions are left out: the series is not drawn from them, so one
    # dated before the real history must not stand in for it. Taken over the
    # accounts the series is built from, not the family's, for a viewer who can
    # see only some of them.
    def account_start_dates
      @account_start_dates ||= begin
        account_ids = BalanceSheet::HistoricalAccountScope.new(balance_sheet.family, user: balance_sheet.user).account_ids
        entry_starts = Entry.where(account_id: account_ids).excluding_pending.group(:account_id).minimum(:date)
        balance_starts = Balance.where(account_id: account_ids).group(:account_id).minimum(:date)
        entry_starts.merge(balance_starts) { |_account_id, entry_start, balance_start| [ entry_start, balance_start ].min }
      end
    end
end
