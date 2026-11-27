class ScalableCapitalItem::Syncer
  include SyncStats::Collector

  SOURCE = "scalable_capital"
  CURRENCY = Provider::ScalableCapital::Snapshot::CURRENCY
  SETTLEMENT_PREFIX = "settlement:"
  SNAPSHOT_STATE_FIELDS = %w[
    family_id owner_id broker_account_id portfolio_id savings_id selected_sources
    broker_synced_through savings_synced_through broker_history_version security_ids import_generation
  ].freeze
  MAX_SNAPSHOT_ATTEMPTS = 2
  StaleSnapshot = Class.new(StandardError)

  def initialize(item, client: Provider::ScalableCapital.new)
    @item = item
    @client = client
  end

  def perform_sync(sync)
    raise Provider::ScalableCapital::Error, "Scalable Capital is disabled for this household" unless @item.configured?

    accounts, skipped = import_latest_snapshot(sync)
    return unless accounts

    accounts.each { |account| account.sync_later(parent_sync: sync) }
    account_ids = accounts.map(&:id)
    collect_transaction_stats(sync, account_ids: account_ids, source: SOURCE)
    collect_trades_stats(sync, account_ids: account_ids, source: SOURCE)
    collect_health_stats(sync)
    report_skipped(skipped) if skipped.positive?
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

    def import_latest_snapshot(sync)
      attempts = 0

      begin
        attempts += 1
        return if sync.cancel_requested?

        state, (snapshots, checkpoints, skipped) = ScalableCapitalItem.with_cli_lock do
          @item.reload
          [ snapshot_state, read_snapshots ]
        end
        return if sync.cancel_requested?

        securities = ScalableCapitalItem::Securities.new(@item, snapshots)
        accounts = @item.with_lock do
          next if sync.cancel_requested?
          raise StaleSnapshot unless snapshot_state == state

          result = import_snapshots(snapshots, securities)
          @item.update!(checkpoints.merge(security_ids: securities.mapping, status: :good, import_generation: @item.import_generation + 1))
          result
        end
        [ accounts, skipped ]
      rescue StaleSnapshot
        retry if attempts < MAX_SNAPSHOT_ATTEMPTS

        raise Provider::ScalableCapital::Error, "Scalable Capital changed during sync. Try again."
      rescue ActiveRecord::Deadlocked
        retry if attempts < MAX_SNAPSHOT_ATTEMPTS

        raise
      end
    end

    def snapshot_state
      @item.attributes.slice(*SNAPSHOT_STATE_FIELDS)
    end

    def read_snapshots
      return read_legacy_snapshots if @item.selected_sources.blank?

      identity = @client.identity
      if identity != @item.broker_account_id
        raise Provider::ScalableCapital::AuthenticationError, "Sign in with the original Scalable account"
      end

      through = Time.at(Time.current.to_i).utc
      skipped = 0
      snapshots = []
      selections = @item.selected_sources.map do |attributes|
        selection = ScalableCapitalItem::Selection.new(attributes, item: @item)
        reader = Provider::ScalableCapital::Snapshot.new(@client, selection, identity: identity, through: through)
        source_snapshots = reader.fetch
        snapshots.concat(source_snapshots.map { |snapshot| snapshot.merge(selection.snapshot_attributes) })
        skipped += reader.skipped
        source_snapshots.empty? ? attributes : selection.advanced(through)
      end
      [ snapshots, { selected_sources: selections }, skipped ]
    end

    def read_legacy_snapshots
      reader = Provider::ScalableCapital::Snapshot.new(@client, @item)
      snapshots = reader.fetch
      checkpoints = {
        broker_account_id: reader.broker_account_id,
        broker_synced_through: [ @item.broker_synced_through, reader.through ].compact.max,
        broker_history_version: ScalableCapitalItem::BROKER_HISTORY_VERSION
      }
      if snapshots.any? { |snapshot| snapshot.fetch(:kind) == :savings }
        checkpoints[:savings_id] = reader.savings_id
        checkpoints[:savings_synced_through] = [ @item.savings_synced_through, reader.through ].compact.max
      end
      [ snapshots, checkpoints, reader.skipped ]
    end

    def import_snapshots(snapshots, securities)
      adapters = snapshots.each_with_object({}) do |snapshot, result|
        source = find_or_create_source(snapshot)
        account = source.account
        next if account.nil? || account.pending_deletion?

        account.lock!
        next unless source.reload.account_provider&.account_id == account.id && !account.pending_deletion?

        result[[ snapshot[:source_key], snapshot.fetch(:kind) ]] = Account::ProviderImportAdapter.new(account)
      end

      lock_affected_transfers(snapshots, adapters)
      securities.resolve_pending! if adapters.keys.any? { |_, kind| kind == :brokerage }

      cash_transaction_ids = snapshots.each_with_object([]) do |snapshot, ids|
        adapter = adapters[[ snapshot[:source_key], snapshot.fetch(:kind) ]]
        next unless adapter

        snapshot.fetch(:entries).each do |entry|
          if entry.key?(:isin)
            import_trade(adapter, adapters[[ snapshot[:source_key], :cash ]], securities, entry)
          elsif (imported = import_transaction(adapter, entry))
            ids << imported.entryable_id
          end
        end
      end

      revalidate_cash_transfers(cash_transaction_ids)

      snapshots.each do |snapshot|
        adapter = adapters[[ snapshot[:source_key], snapshot.fetch(:kind) ]]
        update_balance(adapter, snapshot, securities) if adapter
      end

      adapters.values.map(&:account).select { |account| Account::VISIBLE_STATUSES.include?(account.status) }
    end

    def lock_affected_transfers(snapshots, adapters)
      external_ids = Hash.new { |ids, account_id| ids[account_id] = [] }
      snapshots.each do |snapshot|
        source_key = snapshot[:source_key]
        adapter = adapters[[ source_key, snapshot.fetch(:kind) ]]
        next unless adapter

        snapshot.fetch(:entries).each do |entry|
          id = entry.fetch(:external_id)
          if entry.key?(:isin)
            settlement = "#{SETTLEMENT_PREFIX}#{id}"
            external_ids[adapter.account.id] << settlement
            cash = adapters[[ source_key, :cash ]]
            external_ids[cash.account.id] << settlement if cash
          else
            external_ids[adapter.account.id] << id
          end
        end
      end
      return if external_ids.empty?

      affected_entries = Entry.transactions.where(source: SOURCE)
      affected_entries = external_ids.map { |account_id, ids| affected_entries.where(account_id: account_id, external_id: ids.uniq) }.reduce(&:or)
      # Transfer edits lock the pair before they lock either entry or update fees.
      transfers_for(affected_entries.select(:entryable_id)).order(:id).lock.load
    end

    def find_or_create_source(snapshot)
      source = @item.scalable_capital_accounts.find_or_initialize_by(kind: snapshot.fetch(:kind), source_key: snapshot[:source_key])
      if source.new_record?
        source.save!
        source.create_linked_account!(balance: snapshot.fetch(:balance), cash_balance: snapshot.fetch(:cash),
                                      label: snapshot[:source_label], junior: snapshot[:junior])
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
      settlement_id = "#{SETTLEMENT_PREFIX}#{external_id}"
      trade_ids = entry[:related_trade_ids] || [ external_id ]
      trade_entry = Entry.where(account_id: adapter.account.id, external_id: trade_ids)
      account_ids = [ adapter.account.id, cash_adapter&.account&.id ].compact
      settlement_entries = Entry.transactions.where(account_id: account_ids, external_id: settlement_id)

      # Check the trade and both settlement legs before updating any of them.
      existing = trade_entry.or(settlement_entries).where(source: SOURCE).order(:id).lock
      return if existing.any? { |record| cash_amount_protected?(record) }

      security = securities.resolve(entry.fetch(:isin), entry[:security_name])
      trade = adapter.import_trade(**entry.except(:isin, :security_name, :related_trade_ids), security: security, source: SOURCE, currency: CURRENCY)
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

      cash_leg = import_transaction(cash_adapter, leg.merge(amount: trade.amount)) if cash_adapter
      broker_transaction = broker_leg.transaction
      cash_transaction = cash_leg&.transaction
      reconcile_settlement_transfers([ broker_transaction, cash_transaction ].compact)
      return unless cash_transaction

      inflow, outflow = trade.amount.positive? ? [ broker_transaction, cash_transaction ] : [ cash_transaction, broker_transaction ]
      return if inflow.transfer.present? || outflow.transfer.present?
      return if RejectedTransfer.exists?(inflow_transaction: inflow, outflow_transaction: outflow)

      # A locked date can keep the two imported legs too far apart to pair.
      transfer = Transfer.new(inflow_transaction: inflow, outflow_transaction: outflow, status: :confirmed)
      return unless transfer.save

      transfer.update_investment_contribution!(false) if transfer.investment_contribution_switchable?
    end

    def import_transaction(adapter, entry)
      if entry.fetch(:amount).zero?
        apply_zero_amount(adapter, entry.fetch(:external_id))
        return
      end

      adapter.import_transaction(**entry, source: SOURCE, currency: CURRENCY, allow_heuristic_matching: false)
    end

    def revalidate_cash_transfers(transaction_ids)
      return if transaction_ids.empty?

      # A transfer's other leg can arrive in a later feed in the same sync.
      transfers = transfers_for(transaction_ids)
        .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
      transfers.lock.find_each { |transfer| detach_transfer(transfer) unless transfer.valid? }
    end

    def transfers_for(transaction_ids)
      Transfer.where(inflow_transaction_id: transaction_ids).or(Transfer.where(outflow_transaction_id: transaction_ids))
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

    def reconcile_settlement_transfers(transactions)
      # A corrected trade can change both signs. Validate against the final amounts.
      invalid_transfers = transactions.filter_map(&:transfer).uniq.reject { |transfer| transfer.reload.valid? }
      return if invalid_transfers.empty?

      invalid_transfers.each { |transfer| detach_transfer(transfer) }
      transactions.each(&:reload)
    end

    def detach_transfer(transfer)
      transfer.with_lock do
        legs = [ transfer.inflow_transaction, transfer.outflow_transaction ].select do |transaction|
          entry = transaction&.entry
          entry&.source == SOURCE && entry.external_id.to_s.start_with?(SETTLEMENT_PREFIX)
        end
        # Preserve fees added by a user before we acquired the same row lock as the editor.
        transfer.fee_transactions.update_all(transfer_id: nil)
        transfer.fee_transactions.reset
        transfer.destroy!
        # The two synthetic legs remain cash movements even when Sure cannot pair them.
        legs.each do |transaction|
          transaction.reload
          transaction.update!(kind: "funds_movement") unless transaction.transfer || transaction.kind == "funds_movement"
        end
      end
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
