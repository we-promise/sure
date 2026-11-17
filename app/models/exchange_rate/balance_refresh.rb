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
# a holding or a trade priced in that currency that had no usable rate before
# them: every usable rate in its lookback is one of the new ones, or was stored
# after them by another write, whose own refresh counts these as already
# there. A rate following yesterday's, which the conversion already had,
# changes nothing here. Synced from the earliest such date. Run from
# ExchangeRateBalanceRefreshJob, never inside the write, which can sit in a
# sync's open transaction.
class ExchangeRate::BalanceRefresh
  # `rates` is [{ from:, to:, date:, stored_at: }], the rows a write newly
  # stored and the time it stored them (their created_at).
  def self.schedule(rates)
    new(rates).schedule
  end

  # Queues the refresh for rates a write just stored. Best-effort: the rates
  # are stored either way, so a queue that cannot take the job is recorded for
  # support rather than raised into the write's caller -- or, inside a
  # transaction, into whoever commits it: the job is queued once every open
  # transaction has committed (as ApplicationJob would defer it), within the
  # rescue.
  def self.enqueue(rates, source:, provider: nil)
    ActiveRecord.after_all_transactions_commit do
      ExchangeRateBalanceRefreshJob.perform_later(rates)
    rescue StandardError => e
      Rails.logger.error("Could not queue the balance refresh for #{rates.size} exchange rate(s): #{e.message}")
      Sentry.capture_exception(e)
      DebugLogEntry.capture(
        category: "exchange_rates",
        level: "error",
        message: "Could not queue the balance refresh for newly stored exchange rates: #{e.class} - #{e.message}",
        source: source,
        provider: provider,
        metadata: { rates: rates.map { |rate| rate.slice(:from, :to, :date) } }
      )
    end
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
        stored_at = rows.map { |rate| rate.fetch(:stored_at) }.min
        affected_accounts(from, to, rows.map { |rate| rate[:date].to_date }.uniq, stored_at).each do |account_id, date|
          earliest[account_id] = [ earliest[account_id], date ].compact.min
        end
      end
    end

    # What a balance converted from `from` into an account kept in `to`: an
    # entry already applied (a day of headroom past today, since a sync reads
    # today in the family's zone), a holding whose security is priced in
    # `from`, or a trade priced in `from` with shares in it, which
    # Holding::PortfolioCache prices the security from even at amount 0 (a
    # transfer or split) -- at a date whose lookback holds a new rate and no
    # other usable one stored before it, so the conversion found none before.
    # A rate another write stored later is not one the balance had.
    def affected_accounts(from, to, dates, stored_at)
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
          UNION ALL
          SELECT entries.account_id, entries.date FROM entries
          JOIN trades ON entries.entryable_type = 'Trade' AND trades.id = entries.entryable_id
          WHERE trades.currency = :from AND trades.qty <> 0
            AND entries.date BETWEEN :first_date AND LEAST(:last_date, CAST(:today AS date))
        ) converted
        JOIN accounts ON accounts.id = converted.account_id AND accounts.currency = :to
        WHERE EXISTS (SELECT 1 FROM exchange_rates r
                      WHERE r.from_currency = :from AND r.to_currency = :to AND r.rate > 0
                        AND r.date BETWEEN converted.date - :lookback AND converted.date
                        AND r.date IN (:dates))
          AND NOT EXISTS (SELECT 1 FROM exchange_rates r
                          WHERE r.from_currency = :from AND r.to_currency = :to AND r.rate > 0
                            AND r.date BETWEEN converted.date - :lookback AND converted.date
                            AND r.date NOT IN (:dates) AND r.created_at < :stored_at)
        GROUP BY converted.account_id
      SQL

      binds = {
        from: from, to: to, dates: dates, stored_at: stored_at, today: Date.current + 1.day,
        lookback: ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS,
        first_date: dates.min, last_date: dates.max + ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS
      }

      ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
        .map { |account_id, date| [ account_id, date.to_date ] }
    end
end
