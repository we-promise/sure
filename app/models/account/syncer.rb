class Account::Syncer
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def perform_sync(sync)
    Rails.logger.info("Processing balances (#{account.linked? ? 'reverse' : 'forward'})")
    import_market_data
    post_fixed_return_interest
    materialize_balances(window_start_date: sync.window_start_date)
    apply_provider_balance_overrides
    report_anchor_dated_away_from_holdings
  end

  def perform_post_sync
    account.family.auto_match_transfers!(account: account)
  end

  private
    def materialize_balances(window_start_date: nil)
      strategy = account.linked? ? :reverse : :forward
      Balance::Materializer.new(account, strategy: strategy, window_start_date: window_start_date).materialize_balances
    end

    # Credits any interest that has come due on a fixed-return account. Runs
    # before balances are materialized so the new entries land in this sync's
    # balance series. A failure here must not fail the whole sync — the next
    # sync will post the same periods, since postings are keyed by date.
    def post_fixed_return_interest
      Depository::FixedReturnPoster.new(account).post_due_interest!
    rescue => e
      Rails.logger.error("Error posting fixed-return interest for account #{account.id}: #{e.message}")
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Failed to post fixed-return interest: #{e.class}: #{e.message}",
        source: self.class.name,
        account: account
      )
      Sentry.capture_exception(e)
    end

    # Syncs all the exchange rates + security prices this account needs to display historical chart data
    #
    # This is a *supplemental* sync.  The daily market data sync should have already populated
    # a majority or all of this data, so this is often a no-op.
    #
    # We rescue errors here because if this operation fails, we don't want to fail the entire sync since
    # we have reasonable fallbacks for missing market data.
    def import_market_data
      Account::MarketDataImporter.new(account).import_all
    rescue => e
      Rails.logger.error("Error syncing market data for account #{account.id}: #{e.message}")
      Sentry.capture_exception(e)
    end

    # A provider that dates its holdings itself, but whose balance is anchored
    # on the day of the sync, leaves the two a day apart; the reverse
    # calculator reads the difference as cash, on every day, in the amount of
    # the day's move (#3815 in IBKR, #3874 in Plaid). Nothing fails, so the only
    # place it can show is here, once every provider has written.
    #
    # The log records changes, compared with the account's latest entry from
    # this check: a new or different gap is a warning, a steady one adds
    # nothing, and the dates lining up again is noted, so a gap that later
    # returns is a new finding rather than one already on record.
    def report_anchor_dated_away_from_holdings
      return unless account.linked? && account.has_current_anchor?

      newest_holding = account.holdings.where.not(account_provider_id: nil).order(date: :desc).first
      return if newest_holding.nil?

      holdings_date = newest_holding.date
      anchor_date = account.current_anchor_date
      gap_days = (anchor_date - holdings_date).to_i
      last_gap = last_reported_anchor_gap

      if gap_days.zero?
        return if last_gap.nil? || last_gap.zero?

        record_anchor_gap(newest_holding, anchor_date, holdings_date, 0, level: "info",
                          message: "Balance anchor and newest provider holding are dated alike again")
      else
        return if last_gap == gap_days

        record_anchor_gap(newest_holding, anchor_date, holdings_date, gap_days, level: "warn",
                          message: "Balance anchor dated #{gap_days.abs} day(s) #{gap_days.positive? ? 'after' : 'before'} the newest provider holding")
      end
    rescue => e
      Rails.logger.error("Error checking anchor date for account #{account.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e)
    end

    def last_reported_anchor_gap
      DebugLogEntry
        .where(account: account, category: "provider_sync", source: self.class.name)
        .order(created_at: :desc)
        .pick(Arel.sql("metadata->>'gap_days'"))
        &.to_i
    end

    def record_anchor_gap(newest_holding, anchor_date, holdings_date, gap_days, level:, message:)
      account_provider = newest_holding.account_provider

      DebugLogEntry.capture(
        category: "provider_sync",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: account_provider&.provider_type&.delete_suffix("Account")&.underscore,
        account: account,
        account_provider: account_provider,
        family: account.family,
        metadata: { anchor_date: anchor_date.to_s, holdings_date: holdings_date.to_s, gap_days: gap_days }
      )
    end

    def apply_provider_balance_overrides
      return unless account.linked_to?("IbkrAccount")

      ibkr_account = account.account_providers.find_by(provider_type: "IbkrAccount")&.provider
      return unless ibkr_account

      IbkrAccount::HistoricalBalancesSync.new(ibkr_account).sync!
    rescue => e
      Rails.logger.error("Error syncing IBKR historical balances for account #{account.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e)
    end
end
