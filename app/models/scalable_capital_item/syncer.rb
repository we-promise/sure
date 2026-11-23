class ScalableCapitalItem::Syncer
  include SyncStats::Collector

  SOURCE = "scalable_capital"
  CURRENCY = Provider::ScalableCapital::Snapshot::CURRENCY
  CLI_LOCK_KEY = 439_927_190_381_238_853

  def initialize(item, client: Provider::ScalableCapital.new)
    @item = item
    @client = client
  end

  def perform_sync(sync)
    raise Provider::ScalableCapital::Error, "Scalable Capital is disabled for this household" unless @item.configured?

    with_cli_lock do
      reader = Provider::ScalableCapital::Snapshot.new(@client, @item.reload)
      snapshots = reader.fetch
      next if sync.cancel_requested?

      # Price-provider lookups run before the ledger transaction.
      securities = ScalableCapitalItem::Securities.new(@item, snapshots)
      accounts = @item.with_lock do
        result = import_snapshots(snapshots, securities)
        checkpoints = {
          broker_account_id: reader.broker_account_id,
          broker_synced_through: [ @item.broker_synced_through, reader.through ].compact.max,
          security_ids: securities.mapping,
          status: :good
        }
        if snapshots.any? { |snapshot| snapshot.fetch(:kind) == :savings }
          checkpoints[:savings_id] = reader.savings_id
          checkpoints[:savings_synced_through] = [ @item.savings_synced_through, reader.through ].compact.max
        end
        @item.update!(checkpoints)
        result
      end

      accounts.each { |account| account.sync_later(parent_sync: sync) }
      account_ids = accounts.map(&:id)
      collect_transaction_stats(sync, account_ids: account_ids, source: SOURCE)
      collect_trades_stats(sync, account_ids: account_ids, source: SOURCE)
      collect_health_stats(sync)
      report_skipped(reader.skipped) if reader.skipped.positive?
    end
  rescue Provider::ScalableCapital::AuthenticationError => error
    @item.update!(status: :requires_update)
    report_failure(sync, error, error.message)
    raise
  rescue Provider::ScalableCapital::Error => error
    report_failure(sync, error, error.message)
    raise
  rescue StandardError => error
    # Database and model errors can include provider records. Keep those out of sync history.
    message = "Could not persist Scalable Capital data"
    report_failure(sync, error, message)
    raise Provider::ScalableCapital::Error, message, cause: nil
  end

  def perform_post_sync
  end

  private

    def with_cli_lock
      ScalableCapitalItem.with_connection do |connection|
        unless connection.select_value("SELECT pg_try_advisory_lock(#{CLI_LOCK_KEY})")
          raise Provider::ScalableCapital::Error, "A Scalable Capital sync is already running"
        end

        begin
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{CLI_LOCK_KEY})")
        end
      end
    end

    def import_snapshots(snapshots, securities)
      adapters = snapshots.each_with_object({}) do |snapshot, result|
        source = find_or_create_source(snapshot)
        account = source.account
        next if account.nil? || account.pending_deletion?

        account.lock!
        next unless source.reload.account_provider&.account_id == account.id && !account.pending_deletion?

        result[snapshot.fetch(:kind)] = Account::ProviderImportAdapter.new(account)
      end

      securities.resolve_pending! if adapters[:brokerage]

      snapshots.each do |snapshot|
        adapter = adapters[snapshot.fetch(:kind)]
        next unless adapter

        snapshot.fetch(:entries).each do |entry|
          if entry.key?(:isin)
            import_trade(adapter, adapters[:cash], securities, entry)
          else
            import_transaction(adapter, entry)
          end
        end
      end

      snapshots.each do |snapshot|
        adapter = adapters[snapshot.fetch(:kind)]
        update_balance(adapter, snapshot, securities) if adapter
      end

      adapters.values.map(&:account).select { |account| Account::VISIBLE_STATUSES.include?(account.status) }
    end

    def find_or_create_source(snapshot)
      source = @item.scalable_capital_accounts.find_or_initialize_by(kind: snapshot.fetch(:kind))
      if source.new_record?
        source.save!
        source.create_linked_account!(balance: snapshot.fetch(:balance), cash_balance: snapshot.fetch(:cash))
      end
      source
    end

    def update_balance(adapter, snapshot, securities)
      account = adapter.account
      date = snapshot.fetch(:date)
      return if account.has_current_anchor? && account.current_anchor_date > date

      if snapshot.fetch(:kind) == :brokerage
        provider = account.account_providers.find_by!(provider_type: "ScalableCapitalAccount")
        import_holdings(adapter, provider, date, snapshot.fetch(:positions), securities)
      end
      account.update!(cash_balance: snapshot.fetch(:cash))
      anchor = account.set_current_balance(snapshot.fetch(:balance), date: date, schedule_sync: false)
      raise Provider::ScalableCapital::Error, "Could not record Scalable account balance" unless anchor.success?
    end

    def import_trade(adapter, cash_adapter, securities, entry)
      external_id = entry.fetch(:external_id)
      settlement_id = "settlement:#{external_id}"
      trade_entry = Entry.where(account_id: adapter.account.id, external_id: external_id)
      account_ids = [ adapter.account.id, cash_adapter&.account&.id ].compact
      settlement_entries = Entry.transactions.where(account_id: account_ids, external_id: settlement_id)

      # Check the trade and both settlement legs before updating any of them.
      existing = trade_entry.or(settlement_entries).where(source: SOURCE).order(:id).lock
      return if existing.any? { |record| cash_amount_protected?(record) }

      security = securities.resolve(entry.fetch(:isin), entry[:security_name])
      trade = adapter.import_trade(**entry.except(:isin, :security_name), security: security, source: SOURCE, currency: CURRENCY)
      import_settlement(adapter, cash_adapter, trade, settlement_id)
    end

    def import_settlement(broker_adapter, cash_adapter, trade, id)
      # The trade moves Sure investment cash. Its opposite leg keeps portfolio
      # cash at zero even if the user deliberately unlinked the cash account.
      if trade.amount.zero?
        [ broker_adapter, cash_adapter ].compact.each { |adapter| apply_zero_amount(adapter, id) }
        return
      end

      name = I18n.t("scalable_capital_items.accounts.settlement", name: trade.name)
      leg = { external_id: id, date: trade.date, name: name, kind: "funds_movement" }
      broker_leg = import_transaction(broker_adapter, leg.merge(amount: -trade.amount))
      return unless broker_leg

      unless cash_adapter
        detach_unbalanced_settlement(broker_leg)
        return
      end

      cash_leg = import_transaction(cash_adapter, leg.merge(amount: trade.amount))
      return unless cash_leg

      inflow, outflow = (trade.amount.positive? ? [ broker_leg, cash_leg ] : [ cash_leg, broker_leg ]).map(&:entryable)
      return if inflow.transfer.present? || outflow.transfer.present?
      return if RejectedTransfer.exists?(inflow_transaction: inflow, outflow_transaction: outflow)

      transfer = Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: :confirmed)
      transfer.update_investment_contribution!(false) if transfer.investment_contribution_switchable?
    end

    def import_transaction(adapter, entry)
      return apply_zero_amount(adapter, entry.fetch(:external_id)) if entry.fetch(:amount).zero?

      adapter.import_transaction(**entry, source: SOURCE, currency: CURRENCY, allow_heuristic_matching: false)
    end

    def apply_zero_amount(adapter, external_id)
      entry = adapter.account.entries.transactions.find_by(external_id: external_id, source: SOURCE)
      return unless entry

      entry.lock!
      return if cash_amount_protected?(entry) || entry.amount.zero?

      transaction = entry.transaction
      transfer = transaction.transfer_as_inflow || transaction.transfer_as_outflow
      detach_transfer(transfer) if transfer
      entry.update!(amount: 0)
    end

    def detach_unbalanced_settlement(broker_leg)
      transaction = broker_leg.transaction
      transfer = transaction.transfer
      # The cash account may have been unlinked after these legs were paired.
      return if !transfer || transfer.reload.valid?

      detach_transfer(transfer)
      transaction.reload.update!(kind: "funds_movement")
    end

    def detach_transfer(transfer)
      # Keep separately recorded fees when the pairing is removed.
      transfer.fee_transactions.update_all(transfer_id: nil)
      transfer.fee_transactions.reset
      transfer.destroy!
    end

    def cash_amount_protected?(entry)
      entry.protected_from_sync? || entry.locked?(:amount) || entry.locked?(:currency)
    end

    def import_holdings(adapter, provider, date, positions, securities)
      incoming = positions.map do |position|
        security = securities.resolve(position.fetch(:isin), position[:security_name])
        adapter.import_holding(**position.except(:isin, :security_name), security: security,
                               account_provider_id: provider.id, date: date, source: SOURCE, currency: CURRENCY)
        security.id
      end.to_set

      # Write a zero snapshot for exited positions so reverse materialization
      # stops carrying the old quantity while keeping its historical snapshots.
      previous = provider.holdings.where(date: ..date)
        .select("DISTINCT ON (COALESCE(provider_security_id, security_id)) holdings.*")
        .order(Arel.sql("COALESCE(provider_security_id, security_id), date DESC, id DESC"))
        .includes(:provider_security, :security)
      previous.each do |holding|
        security = holding.provider_security || holding.security
        next if holding.qty.zero? || incoming.include?(security.id)

        adapter.import_holding(security: security, quantity: 0, amount: 0, price: 0,
                               account_provider_id: provider.id, date: date, source: SOURCE, currency: CURRENCY)
      end
    end

    def report_failure(sync, error, message)
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "error", source: self.class.name,
        provider_key: SOURCE, family: @item.family, message: message,
        metadata: { error_class: error.class.name, connection_id: @item.id }
      )
      collect_health_stats(sync, errors: [ { message: message, category: "sync_error" } ])
    end

    def report_skipped(count)
      DebugLogEntry.capture(
        category: "provider_sync", level: "warn", source: self.class.name,
        provider_key: SOURCE, family: @item.family, message: "Unsupported Scalable activity was skipped",
        metadata: { skipped_count: count }
      )
    end
end
