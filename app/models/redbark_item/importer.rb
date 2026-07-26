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

    stats
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
        capture_failure("Connections fetch failed; institution metadata will be limited", e)
        {}
      end
    end

    def import_accounts
      Rails.logger.info "RedbarkItem::Importer - Fetching accounts"

      accounts_data = redbark_provider.list_accounts

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      # Fetch connections once, before the per-account rescue below - an auth
      # failure here must propagate and mark the item requires_update, not get
      # swallowed as N per-account errors
      connections_by_id

      upstream_account_ids = []

      accounts_data.each do |account_data|
        begin
          account_id = account_data[:id]&.to_s
          next if account_id.blank?
          next if account_data[:name].blank?

          # Only banking and documents connections carry transactions;
          # brokerage accounts belong to /v1/trades and are out of scope here
          connection = connections_by_id[account_data[:connectionId].to_s]
          next unless transactable_connection?(connection)

          upstream_account_ids << account_id

          redbark_account = redbark_item.redbark_accounts.find_or_initialize_by(
            redbark_account_id: account_id
          )
          redbark_account.upsert_from_redbark!(account_data, connection_data: connection)

          stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
        rescue => e
          capture_failure("Account import failed", e, account_id: account_data[:id])
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_id: account_data[:id])
        end
      end

      persist_stats!

      @upstream_account_ids = upstream_account_ids

      prune_removed_accounts(upstream_account_ids)
    end

    def import_transactions(redbark_account)
      Rails.logger.info "RedbarkItem::Importer - Fetching transactions for account #{redbark_account.id}"

      if redbark_account.connection_id.blank?
        Rails.logger.warn "RedbarkItem::Importer - Account #{redbark_account.id} has no connection_id, skipping transactions"
        return
      end

      # A linked account can still sit on a non-transactable connection
      # (e.g. brokerage rows linked before this guard existed) - the
      # transactions endpoint rejects those outright
      connection = connections_by_id[redbark_account.connection_id.to_s]
      unless transactable_connection?(connection)
        Rails.logger.info "RedbarkItem::Importer - Skipping transactions for non-banking account #{redbark_account.id}"
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
          merged = merge_transactions(
            redbark_account.raw_transactions_payload || [],
            transactions_hashes,
            window_start: start_date
          )
          redbark_account.upsert_redbark_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue Provider::Redbark::AuthenticationError
        raise
      rescue => e
        capture_failure("Transactions fetch failed", e, account_id: redbark_account.redbark_account_id)
        register_error(e, context: "transactions", account_id: redbark_account.id)
      end
    end

    # One balances call covers every eligible linked account. A failed fetch
    # leaves current_balance untouched so the processor keeps the previous
    # balance instead of writing zeros.
    def import_balances(linked_accounts)
      eligible_accounts = balance_eligible_accounts(linked_accounts)
      account_ids = eligible_accounts.map(&:redbark_account_id).compact
      return if account_ids.empty?

      begin
        balances = fetch_balances_with_fallback(account_ids)

        balances_by_id = balances.index_by { |b| b[:accountId].to_s }

        eligible_accounts.each do |redbark_account|
          balance_data = balances_by_id[redbark_account.redbark_account_id]
          next unless balance_data

          amount = parse_decimal(balance_data[:currentBalance])
          next if amount.nil?

          redbark_account.update!(
            current_balance: amount,
            currency: extract_currency(balance_data, fallback: redbark_account.currency)
          )
          stats["balances_updated"] = stats.fetch("balances_updated", 0) + 1
        end
      rescue Provider::Redbark::AuthenticationError
        raise
      rescue => e
        capture_failure("Balances fetch failed; keeping previous balances", e)
        register_error(e, context: "balances")
      end
    end

    # The balances endpoint rejects the WHOLE batch when any requested id is
    # unknown (404) or non-banking (400), so exclude accounts that no longer
    # exist upstream and accounts on non-banking connections up front.
    def balance_eligible_accounts(linked_accounts)
      linked_accounts.select do |redbark_account|
        next false if redbark_account.redbark_account_id.blank?

        if @upstream_account_ids.present? && !@upstream_account_ids.include?(redbark_account.redbark_account_id)
          next false
        end

        connection = connections_by_id[redbark_account.connection_id.to_s]
        next true if connection.nil? # no connection metadata - let the fallback sort it out

        category = connection[:category].to_s
        category.blank? || category == "banking"
      end
    end

    # If the batch is still rejected (stale id or category we could not see),
    # fall back to per-account requests so one bad account cannot freeze
    # balance updates for the rest of the item.
    def fetch_balances_with_fallback(account_ids)
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      redbark_provider.get_balances(account_ids: account_ids)
    rescue Provider::Redbark::AuthenticationError
      raise
    rescue Provider::Redbark::Error => e
      raise unless %i[not_found bad_request].include?(e.error_type)
      raise if account_ids.size <= 1

      capture_failure("Batched balances call rejected; retrying per account", e)

      account_ids.flat_map do |account_id|
        begin
          stats["api_requests"] = stats.fetch("api_requests", 0) + 1
          redbark_provider.get_balances(account_ids: [ account_id ])
        rescue Provider::Redbark::AuthenticationError
          raise
        rescue Provider::Redbark::Error => account_error
          capture_failure("Balance fetch failed for account; keeping previous balance", account_error, account_id: account_id)
          []
        end
      end
    end

    def calculate_transaction_start_date(redbark_account)
      has_stored_transactions = (redbark_account.raw_transactions_payload || []).any?

      if has_stored_transactions && redbark_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch late-posting
        # transactions. The user's sync_start_date governs the initial
        # backfill only - re-fetching the whole window every sync would blow
        # through the API's row ceiling on busy accounts.
        (redbark_item.last_synced_at - 7.days).to_date
      elsif redbark_account.sync_start_date.present?
        redbark_account.sync_start_date
      else
        # First sync for this account: pull a 90 day history
        90.days.ago.to_date
      end
    end

    # The snapshot is bounded to the current fetch window - durable history
    # lives in entries (deduped by external_id), so older rows are dropped
    # rather than accumulated forever. Rows without a parseable date are kept.
    # A pending row absent from the refetch has settled (possibly under a new
    # id) - keeping it would duplicate the posted transaction.
    def merge_transactions(existing, new_transactions, window_start: nil)
      new_keys = new_transactions.map { |t| transaction_key(t) }.to_set

      by_id = {}
      existing.each do |t|
        next unless within_window?(t, window_start)
        next if stale_pending?(t, new_keys)
        by_id[transaction_key(t)] = t
      end
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def within_window?(transaction, window_start)
      return true if window_start.nil?

      t = transaction.is_a?(Hash) ? transaction.with_indifferent_access : transaction
      date = Date.parse(t[:date].to_s) rescue nil
      date.nil? || date >= window_start
    end

    def stale_pending?(transaction, new_keys)
      t = transaction.is_a?(Hash) ? transaction.with_indifferent_access : transaction
      t[:status].to_s == "pending" && !new_keys.include?(transaction_key(t))
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
          capture_failure("Failed to prune orphaned account", e, redbark_account_id: redbark_account.id)
        end
      end
    end

    # Banking and documents connections serve /v1/transactions; anything else
    # (brokerage) does not. Unknown connections get the benefit of the doubt.
    def transactable_connection?(connection)
      return true if connection.nil?

      category = connection[:category].to_s
      category.blank? || %w[banking documents].include?(category)
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end

    # Surfaces provider failures in the /settings/debug super-admin UI so
    # support can diagnose without log access
    def capture_failure(message, error, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "redbark",
        family: redbark_item.family,
        metadata: { error_class: error.class.name, error: error.message }.merge(metadata)
      )
      Rails.logger.warn "RedbarkItem::Importer - #{message}: #{error.class}: #{error.message}"
    end
end
