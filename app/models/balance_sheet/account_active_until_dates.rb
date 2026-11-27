# The date after which an account contributes nothing to a chart: the earlier
# of its disabled cutoff and its last zero-balance entry.
class BalanceSheet::AccountActiveUntilDates
  def initialize(accounts)
    @accounts = accounts
  end

  def to_h
    disabled_dates.merge(zero_balance_dates) do |_account_id, disabled_until, zero_until|
      [ disabled_until, zero_until ].min
    end
  end

  private
    attr_reader :accounts

    def disabled_dates
      accounts.each_with_object({}) do |account, dates|
        next unless account.disabled?

        disabled_on = (account.disabled_at || account.updated_at).to_date
        dates[account.id] = disabled_on - 1.day
      end
    end

    # A zero balance is carried forward, so the account contributes nothing
    # after its last entry. An account still holding a balance stays in.
    def zero_balance_dates
      latest_balances.each_with_object({}) do |(account_id, date, end_balance), dates|
        dates[account_id] = date if end_balance.zero?
      end
    end

    # One indexed lookup per account. A `DISTINCT ON` over the account's whole
    # balance history reads every row on a cache miss.
    def latest_balances
      ids = accounts.map(&:id)
      return [] if ids.empty?

      Account
        .where(id: ids)
        .joins(<<~SQL.squish)
          CROSS JOIN LATERAL (
            SELECT balances.account_id, balances.date, balances.end_balance
            FROM balances
            WHERE balances.account_id = accounts.id
              AND balances.currency = accounts.currency
            ORDER BY balances.date DESC
            LIMIT 1
          ) latest_balances
        SQL
        .pluck("latest_balances.account_id", "latest_balances.date", "latest_balances.end_balance")
    end
end
