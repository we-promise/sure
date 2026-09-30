class Account::Syncer
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def perform_sync(sync)
    Rails.logger.info("Processing balances (#{account.linked? ? 'reverse' : 'forward'})")
    import_market_data
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
    # place it can show is here, once every provider has written. One entry per
    # distinct gap: the same pair of dates on the next sync adds nothing.
    def report_anchor_dated_away_from_holdings
      return unless account.linked? && account.has_current_anchor?

      holdings_date = account.latest_provider_holdings_snapshot_date
      return if holdings_date.nil?

      anchor_date = account.current_anchor_date
      return if anchor_date == holdings_date
      return if anchor_gap_already_reported?(anchor_date, holdings_date)

      gap_days = (anchor_date - holdings_date).to_i
      account_provider = account.account_providers.first

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Balance anchor dated #{gap_days.abs} day(s) #{gap_days.positive? ? 'after' : 'before'} the newest provider holding",
        source: self.class.name,
        provider_key: account_provider&.provider_type&.delete_suffix("Account")&.underscore,
        account: account,
        account_provider: account_provider,
        family: account.family,
        metadata: { anchor_date: anchor_date.to_s, holdings_date: holdings_date.to_s, gap_days: gap_days }
      )
    rescue => e
      Rails.logger.error("Error checking anchor date for account #{account.id}: #{e.class} - #{e.message}")
    end

    def anchor_gap_already_reported?(anchor_date, holdings_date)
      DebugLogEntry
        .where(account: account, category: "provider_sync", source: self.class.name)
        .where("metadata->>'anchor_date' = ? AND metadata->>'holdings_date' = ?", anchor_date.to_s, holdings_date.to_s)
        .exists?
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
