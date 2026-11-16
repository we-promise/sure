# Rebuilds the balances a stored or changed exchange rate would have fed.
#
# Balance::SyncCache converts each foreign-currency entry into its account's
# currency when the balances are materialized, at the rate stored then: the
# latest usable one up to NEAREST_RATE_LOOKBACK_DAYS before the date. With
# none, the entry is dropped. Holding::PortfolioCache converts a security's
# price the same way and falls back to 1:1. Nothing rebuilt those balances
# when the rate arrived or was corrected later, so a balance stayed wrong until
# something else happened to sync the account.
#
# Given the rates a write newly stored, this syncs every account with an entry,
# or a holding priced in that currency, that had no usable rate before them:
# every usable rate in its lookback is one of the new ones. A rate following
# yesterday's, which the conversion already had, changes nothing here. Synced
# from the earliest such date. Run from ExchangeRateBalanceRefreshJob, never
# inside the write, which can sit in a sync's open transaction.
class ExchangeRate::BalanceRefresh
  # `rates` is [{ from:, to:, date: }], the rows a write newly stored.
  def self.schedule(rates)
    new(rates).schedule
  end

  def initialize(rates)
    @rates = Array(rates)
  end

  def schedule
    dates = earliest_dates
    return if dates.empty?

    Account.visible.where(id: dates.keys).find_each do |account|
      refresh(account, dates.fetch(account.id))
    end
  end

  private
    attr_reader :rates

    # A running sync cannot widen its window (Sync#expand_window_if_needed
    # only widens a pending one), so it is asked for a full resync once it
    # finishes, as Sync#queue_full_resync does -- checked under its lock, so a
    # sync that finished meanwhile is not flagged after it read the flag.
    # Otherwise the account syncs from the date, merged into any sync still
    # pending.
    def refresh(account, date)
      running = account.syncs.visible.where(status: "syncing").first
      flagged = running&.with_lock do
        running.syncing? && running.update!(full_resync_requested: true)
      end

      account.sync_later(window_start_date: date) unless flagged
    end

    # { account_id => earliest affected date } across every changed pair.
    def earliest_dates
      rates.group_by { |rate| [ rate[:from], rate[:to] ] }.each_with_object({}) do |((from, to), rows), earliest|
        affected_accounts(from, to, rows.map { |rate| rate[:date].to_date }.uniq).each do |account_id, date|
          earliest[account_id] = [ earliest[account_id], date ].compact.min
        end
      end
    end

    # What a balance converted from `from` into an account kept in `to`: an
    # entry already applied (a day of headroom past today, since a sync reads
    # today in the family's zone), or a holding whose security is priced in
    # `from` -- at a date whose lookback holds a new rate and no other usable
    # one, so the conversion found none before.
    def affected_accounts(from, to, dates)
      sql = <<~SQL
        SELECT converted.account_id, MIN(converted.date)
        FROM (
          SELECT entries.account_id, entries.date FROM entries
          WHERE entries.currency = :from AND entries.amount <> 0
            AND entries.date BETWEEN :first_date AND LEAST(:last_date, CAST(:today AS date))
          UNION ALL
          SELECT holdings.account_id, holdings.date FROM holdings
          WHERE holdings.amount <> 0
            AND holdings.date BETWEEN :first_date AND :last_date
            AND (holdings.currency = :from OR EXISTS (
              SELECT 1 FROM security_prices sp WHERE sp.security_id = holdings.security_id AND sp.currency = :from))
        ) converted
        JOIN accounts ON accounts.id = converted.account_id AND accounts.currency = :to
        WHERE EXISTS (SELECT 1 FROM exchange_rates r
                      WHERE r.from_currency = :from AND r.to_currency = :to AND r.rate > 0
                        AND r.date BETWEEN converted.date - :lookback AND converted.date
                        AND r.date IN (:dates))
          AND NOT EXISTS (SELECT 1 FROM exchange_rates r
                          WHERE r.from_currency = :from AND r.to_currency = :to AND r.rate > 0
                            AND r.date BETWEEN converted.date - :lookback AND converted.date
                            AND r.date NOT IN (:dates))
        GROUP BY converted.account_id
      SQL

      binds = {
        from: from, to: to, dates: dates, today: Date.current + 1.day,
        lookback: ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS,
        first_date: dates.min, last_date: dates.max + ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS
      }

      ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
        .map { |account_id, date| [ account_id, date.to_date ] }
    end
end
