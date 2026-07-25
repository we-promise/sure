# frozen_string_literal: true

class RedbarkItem::Importer
  include SyncStats::Collector
  include RedbarkAccount::DataHelpers
  include CurrencyNormalizable

  attr_reader :redbark_item, :redbark_provider, :sync

  def initialize(redbark_item, redbark_provider:, sync: nil)
    @redbark_item = redbark_item
    @redbark_provider = redbark_provider
    @sync = sync
  end

  def import
    Rails.logger.info "RedbarkItem::Importer - Starting import for item #{redbark_item.id}"

    # Step 1: Fetch and store all accounts (with connection metadata for institutions)
    import_accounts

    # Step 2: For linked accounts only, fetch transactions and balances.
    # Unlinked accounts just need basic info (name, institution) for the setup modal.
    linked_accounts = redbark_item.linked_redbark_accounts.to_a

    Rails.logger.info "RedbarkItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |redbark_account|
      import_transactions(redbark_account)
    end

    import_balances(linked_accounts)

    # Store import stats on the item as the raw snapshot
    redbark_item.upsert_redbark_snapshot!(stats)
  rescue Provider::Redbark::AuthenticationError
    redbark_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def connections_by_id
      @connections_by_id ||= begin
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1
        redbark_provider.list_connections.index_by { |c| c[:id].to_s }
      rescue Provider::Redbark::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "RedbarkItem::Importer - Failed to fetch connections (institution metadata will be limited): #{e.message}"
        {}
      end
    end

    def import_accounts
      Rails.logger.info "RedbarkItem::Importer - Fetching accounts"

      accounts_data = redbark_provider.list_accounts

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      upstream_account_ids = []

      accounts_data.each do |account_data|
        begin
          account_id = account_data[:id]&.to_s
          next if account_id.blank?
          next if account_data[:name].blank?

          upstream_account_ids << account_id

          redbark_account = redbark_item.redbark_accounts.find_or_initialize_by(
            redbark_account_id: account_id
          )
          connection = connections_by_id[account_data[:connectionId].to_s]
          redbark_account.upsert_from_redbark!(account_data, connection_data: connection)

          stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
        rescue => e
          Rails.logger.error "RedbarkItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_id: account_data[:id])
        end
      end

      persist_stats!

      prune_removed_accounts(upstream_account_ids)
    end

    def import_transactions(redbark_account)
      Rails.logger.info "RedbarkItem::Importer - Fetching transactions for account #{redbark_account.id}"

      if redbark_account.connection_id.blank?
        Rails.logger.warn "RedbarkItem::Importer - Account #{redbark_account.id} has no connection_id, skipping transactions"
        return
      end

      begin
        start_date = calculate_transaction_start_date(redbark_account)

        transactions_data = redbark_provider.get_transactions(
          connection_id: redbark_account.connection_id,
          account_id: redbark_account.redbark_account_id,
          start_date: start_date,
          end_date: Date.current,
          include_pending: Rails.configuration.x.redbark.include_pending
        )

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if transactions_data.any?
          transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(redbark_account.raw_transactions_payload || [], transactions_hashes)
          redbark_account.upsert_redbark_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue Provider::Redbark::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "RedbarkItem::Importer - Failed to fetch transactions: #{e.message}"
        register_error(e, context: "transactions", account_id: redbark_account.id)
      end
    end

    # One balances call covers every linked account. A failed fetch leaves
    # current_balance untouched so the processor keeps the previous balance
    # instead of writing zeros.
    def import_balances(linked_accounts)
      account_ids = linked_accounts.map(&:redbark_account_id).compact
      return if account_ids.empty?

      begin
        balances = redbark_provider.get_balances(account_ids: account_ids)
        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        balances_by_id = balances.index_by { |b| b[:accountId].to_s }

        linked_accounts.each do |redbark_account|
          balance_data = balances_by_id[redbark_account.redbark_account_id]
          next unless balance_data

          amount = parse_decimal(balance_data[:currentBalance])
          next if amount.nil?

          redbark_account.update!(
            current_balance: amount,
            currency: parse_currency(balance_data[:currency]) || redbark_account.currency
          )
          stats["balances_updated"] = stats.fetch("balances_updated", 0) + 1
        end
      rescue Provider::Redbark::AuthenticationError
        raise
      rescue => e
        Rails.logger.warn "RedbarkItem::Importer - Failed to fetch balances: #{e.message}"
        register_error(e, context: "balances")
      end
    end

    def calculate_transaction_start_date(redbark_account)
      user_start = redbark_account.sync_start_date
      return user_start if user_start.present?

      has_stored_transactions = (redbark_account.raw_transactions_payload || []).any?

      if has_stored_transactions && redbark_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch late-posting transactions
        (redbark_item.last_synced_at - 7.days).to_date
      else
        # First sync for this account: pull a 90 day history
        90.days.ago.to_date
      end
    end

    def merge_transactions(existing, new_transactions)
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def transaction_key(transaction)
      transaction = transaction.with_indifferent_access if transaction.is_a?(Hash)
      transaction[:id].presence ||
        [ transaction[:date], transaction[:amount], transaction[:description] ].join("-")
    end

    # Removes records that no longer exist upstream and are not linked to any
    # Account. Guarded to a non-empty upstream list so a transient empty or
    # failed response can never wipe out all accounts.
    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      scope = redbark_item.redbark_accounts.includes(:account_provider)
      orphaned = scope
        .where.not(redbark_account_id: upstream_account_ids)
        .or(scope.where(redbark_account_id: nil))

      orphaned.each do |redbark_account|
        if redbark_account.account_provider.present?
          Rails.logger.info "RedbarkItem::Importer - Keeping stale RedbarkAccount #{redbark_account.id} (still linked to an Account)"
          next
        end

        begin
          Rails.logger.info "RedbarkItem::Importer - Pruning orphaned RedbarkAccount #{redbark_account.id} (no longer exists upstream)"
          redbark_account.destroy
          stats["accounts_pruned"] = stats.fetch("accounts_pruned", 0) + 1
        rescue => e
          Rails.logger.error "RedbarkItem::Importer - Failed to prune RedbarkAccount #{redbark_account.id}: #{e.message}"
        end
      end
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
