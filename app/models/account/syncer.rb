class Account::Syncer
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def perform_sync(sync)
    Rails.logger.info("Processing balances (#{account.linked? ? 'reverse' : 'forward'})")
    import_market_data
    accruals_changed = accrue_loan_interest
    materialize_balances(window_start_date: accruals_changed ? nil : sync.window_start_date)
    apply_provider_balance_overrides
  end

  def perform_post_sync
    account.family.auto_match_transfers!(account: account)
  end

  private
    # Posts this loan's monthly interest charges before balances are materialized,
    # so a payment into the account reduces principal only. No-op unless the user
    # opted the loan in.
    #
    # When anything changed we drop the incremental window and force a full
    # recalculation: an accrual can be created or re-priced at a date earlier than
    # the window, which would otherwise be seeded from a now-stale persisted
    # balance. Failures are swallowed — an accrual problem should degrade the loan
    # to its pre-existing behaviour, not fail the whole account sync.
    def accrue_loan_interest
      return false unless account.loan?

      Loan::InterestAccrual.new(account.loan).sync!
    rescue => e
      Rails.logger.error("Error accruing loan interest for account #{account.id}: #{e.message}")
      Sentry.capture_exception(e)
      false
    end

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
