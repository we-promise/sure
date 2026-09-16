class Account::Syncer
  attr_reader :account

  def initialize(account)
    @account = account
    @account_id, @family_id = account.id, account.family_id
  end

  def perform_sync(sync)
    refresh_account!
    Rails.logger.info("Processing balances (#{account.linked? ? 'reverse' : 'forward'})")
    if sync.is_a?(Sync)
      sync.reload
      unless sync.syncable_type == "Account" && sync.syncable_id == account.id && sync.account_family_id == @family_id
        raise Provider::AccountData::InvalidResponse, "Account calculation belongs to another account"
      end
      Account::SyncQueue.new(account).seal_existing!(sync)
      return if sync.account_materialized_at
      inputs = sync.verify_account_inputs!
      if inputs.any?
        return materialize_native_history(sync, inputs)
      elsif native_historical_owner?
        raise Provider::AccountData::IncompletePage, "Native historical source has no sealed account input"
      end
    end
    import_market_data
    Account.transaction(requires_new: true) do
      refresh_account!(lock: true)
      with_current_sync(sync) do
        ExchangeRate.with_cached_rates_only do
          materialize_balances(window_start_date: sync.window_start_date)
        end
      end
    end
    apply_provider_balance_overrides(sync)
  end

  def perform_post_sync
    account.family.auto_match_transfers!(account: account)
  end

  private
    def materialize_native_history(sync, inputs)
      unless inputs.one? && inputs.first.kind == "ibkr_equity"
        raise Provider::AccountData::InvalidResponse, "Unsupported account calculation input set"
      end
      input = inputs.first
      resolved = input.resolve!
      import_market_data
      refresh_account!
      preparation = sync.account_sync_preparation
      unless preparation
        # Trade FX preparation may perform I/O. Re-admit its owner afterwards,
        # then retain the result separately from the financial transaction so a
        # later calculation failure can retry the same preparation.
        snapshot = Ingestion::HistoricalBalances::TradeFlowSnapshot.capture(account: account)
        preparation = with_native_publication(sync, input, resolved.fetch(:source_batch)) do
          sync.account_sync_preparation || sync.create_account_sync_preparation!(input_digest: sync.account_inputs_digest, payload: snapshot.payload)
        end
      end
      return unless preparation
      trade_flows = preparation.trade_flows
      connection = resolved.fetch(:external_account).provider_connection
      # Row order: connection -> captured grant (provider Sync/settings/family) -> Account -> child Sync -> external/link/policies ->
      # Entries/entryables -> balances/holdings. No external I/O is permitted.
      with_native_publication(sync, input, resolved.fetch(:source_batch)) do
        current_input = sync.verify_account_inputs!.sole
        external = connection.external_accounts.lock.find(current_input.payload.fetch("external_account_id"))
        AccountProvider.where(external_account_id: external.id).order(:id).lock.load
        Account::SourcePolicy.active.where(account: account, resource: %w[historical_balances balances]).order(:id).lock.load
        resolved = current_input.resolve!
        financial = Ingestion::HistoricalBalances::Inputs.capture(account, lock: true)
        trade_flows.resolve(inputs: financial, currency: account.currency)
        # Transaction metadata affects pending/exclusion and custom FX in
        # the ordinary materializer, so pin those entryables as well.
        ids = financial.fetch("entries").select { |row| row.fetch("entryable_type") == "Transaction" }.map { |row| row.fetch("entryable_id") }.uniq.sort
        transactions = ids.each_slice(1_000).flat_map { |slice| Transaction.where(id: slice).order(:id).lock.to_a }
        validate_custom_rates!(financial, transactions)
        account.holdings.order(:id).lock.load
        plan = Ingestion::HistoricalBalances::IbkrPlan.new(**resolved, capture_revision: sync.id, trade_flow_snapshot: trade_flows)
        opening = plan.capture!(phase: "opening_anchor")
        Ingestion::HistoricalBalances::Writer.new(batch: opening).apply!
        # Market-data preparation can memoize the old opening-balance
        # manager. AR reload does not clear that PORO's valuation cache.
        @account = Account.find(account.id)
        ExchangeRate.with_cached_rates_only do
          materialize_balances(window_start_date: sync.window_start_date)
        end
        history = plan.capture!(phase: "equity_history")
        Ingestion::HistoricalBalances::Writer.new(batch: history).apply!
        sync.update!(account_materialized_at: Time.current)
      end
    rescue StandardError => error
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Native account calculation did not complete",
        source: self.class.name, provider_key: "ibkr", family: account.family, account: account,
        metadata: { sync_id: sync.id, account_sync_input_id: inputs.first&.id, error_class: error.class.name })
      raise
    end

    def refresh_account!(lock: false)
      @account = Account::SyncAdmission.fetch!(account_id: @account_id, family_id: @family_id, lock: lock)
    end

    def with_native_publication(sync, input, source_batch)
      Provider::AccountData::Ibkr::EquityHandoff.with_source_grant(source_batch: source_batch) do
        input.provider_sync.lock!("FOR KEY SHARE")
        refresh_account!(lock: true)
        with_current_sync(sync) do
          next if sync.account_materialized_at
          yield
        end
      end
    end

    def with_current_sync(sync)
      return yield unless sync.is_a?(Sync)

      sync.with_lock do
        unless sync.syncable_type == "Account" && sync.syncable_id == @account_id && sync.account_family_id == @family_id &&
            sync.syncing? && !sync.cancel_requested_at? && !sync.send(:continuation_cancelled?)
          raise Provider::AccountData::StaleWriter, "Account calculation was cancelled or finalized"
        end
        yield
      end
    end

    def native_historical_owner?
      policy = Account::SourcePolicy.active.find_by(account: account, resource: "historical_balances")
      policy&.account_provider&.external_account&.provider_key == "ibkr"
    end

    def validate_custom_rates!(financial, transactions)
      entryables = transactions.index_by { |record| [ "Transaction", record.id ] }
      financial.fetch("trades").each { |row| entryables[[ "Trade", row.fetch("id") ]] = row }
      financial.fetch("entries").each do |entry|
        next if entry.fetch("currency") == account.currency
        value = entryables[[ entry.fetch("entryable_type"), entry.fetch("entryable_id") ]]
        extra = value.is_a?(Hash) ? value["extra"] : value&.extra
        raw = extra.to_h["exchange_rate"]
        next if raw.blank?
        rate = raw.is_a?(Float) ? raw.to_d : BigDecimal(raw.to_s)
        unless rate.finite? && rate.positive?
          raise ExchangeRate::Provided::MissingCachedRate, "Stored account exchange rate is invalid"
        end
      end
    rescue ArgumentError, TypeError
      raise ExchangeRate::Provided::MissingCachedRate, "Stored account exchange rate is invalid", cause: nil
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
    # A preparation failure can still leave usable cached data. Publication
    # checks required FX rates separately and refuses to fetch while locked.
    def import_market_data
      Account::MarketDataImporter.new(account).import_all
    rescue => e
      Rails.logger.error("Error syncing market data for account #{account.id}: #{e.message}")
      Sentry.capture_exception(e)
    end

    def apply_provider_balance_overrides(sync)
      return unless account.linked_to?("IbkrAccount")

      ibkr_account = account.account_providers.find_by(provider_type: "IbkrAccount")&.provider
      return unless ibkr_account

      Provider::AccountData::LegacyWriterFence.with_account(ibkr_account) do |current|
        Account.transaction(requires_new: true) do
          refresh_account!(lock: true)
          with_current_sync(sync) do
            link = AccountProvider.where(account_id: account.id, provider_type: "IbkrAccount", provider_id: current.id)
              .lock("FOR UPDATE NOWAIT").first
            raise Account::SyncAdmission::Unavailable, "Historical account link is unavailable for synchronization" unless link

            link.association(:account).target = account
            current.association(:account_provider).target = link
            current.association(:account).target = account
            current.association(:linked_account).target = account
            ExchangeRate.with_cached_rates_only { IbkrAccount::HistoricalBalancesSync.new(current).sync! }
          end
        end
      end
    rescue Provider::AccountData::StaleWriter, ActiveRecord::LockWaitTimeout, ExchangeRate::Provided::MissingCachedRate
      raise
    rescue => e
      Rails.logger.error("Error syncing IBKR historical balances for account #{account.id}: #{e.class} - #{e.message}")
      Sentry.capture_exception(e)
    end
end
