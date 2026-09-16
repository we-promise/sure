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
