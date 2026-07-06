class OpenBankingIoItem::Importer
  attr_reader :open_banking_io_item, :open_banking_io_provider

  def initialize(open_banking_io_item, open_banking_io_provider:)
    @open_banking_io_item = open_banking_io_item
    @open_banking_io_provider = open_banking_io_provider
  end

  def import
    Rails.logger.info "OpenBankingIoItem::Importer - Starting import for item #{open_banking_io_item.id}"

    trigger_upstream_sync

    accounts_data = fetch_accounts_data
    return failed_result("Failed to fetch accounts data") unless accounts_data

    open_banking_io_item.upsert_open_banking_io_snapshot!(accounts_data)

    account_stats = import_accounts(accounts_data)
    transaction_stats = import_transactions

    Rails.logger.info(
      "OpenBankingIoItem::Importer - Completed import for item #{open_banking_io_item.id}: " \
      "#{account_stats[:updated]} accounts updated, #{account_stats[:created]} new accounts discovered, " \
      "#{transaction_stats[:imported]} transactions"
    )

    {
      success: account_stats[:failed].zero? && transaction_stats[:failed].zero?,
      accounts_updated: account_stats[:updated],
      accounts_created: account_stats[:created],
      accounts_failed: account_stats[:failed],
      transactions_imported: transaction_stats[:imported],
      transactions_failed: transaction_stats[:failed]
    }
  end

  private

    # Best-effort: ask open-banking.io to pull fresh data from the upstream banks
    # BEFORE we paginate, so `get_accounts`/`get_transactions` read refreshed data
    # instead of re-importing a stale cached window. A sync failure (e.g. an
    # account whose bank session expired) must never abort importing the cached
    # data we already have, so it is swallowed and surfaced via DebugLogEntry.
    def trigger_upstream_sync
      open_banking_io_provider.sync_all
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Upstream sync failed (continuing with cached data): #{e.class}"
      capture_sync_error("Failed to trigger upstream open-banking.io sync", e)
    end

    def fetch_accounts_data
      items = open_banking_io_provider.get_accounts
      { items: items }
    rescue Provider::OpenBankingIo::Error => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "OpenBankingIoItem::Importer - open-banking.io API error: #{e.error_type}"
      capture_sync_error("Failed to fetch accounts data", e, error_type: e.error_type)
      nil
    rescue JSON::ParserError => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to parse open-banking.io API response: #{e.class}"
      capture_sync_error("Failed to parse open-banking.io accounts response", e)
      nil
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Unexpected error fetching accounts: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      capture_sync_error("Unexpected error fetching accounts", e)
      nil
    end

    def import_accounts(accounts_data)
      stats = { updated: 0, created: 0, failed: 0 }
      accounts = Array(accounts_data[:items])
      # Preload every existing provider account once, keyed by external id, so the
      # per-account refresh is an in-memory lookup instead of a find_by per row (N+1).
      existing_by_id = open_banking_io_item.open_banking_io_accounts.index_by { |a| a.account_id.to_s }

      accounts.each do |account_data|
        account = account_data.with_indifferent_access
        account_id = account[:id].presence
        next if account_id.blank?

        existing = existing_by_id[account_id.to_s]
        if existing
          # Refresh the snapshot for ANY already-known account, linked or not.
          # An existing-but-unlinked account previously matched neither branch,
          # so its name/currency/balance snapshot went stale every sync until a
          # user linked it. Refreshing here keeps unlinked accounts current.
          existing.upsert_open_banking_io_snapshot!(account)
          stats[:updated] += 1
        else
          open_banking_io_account = open_banking_io_item.open_banking_io_accounts.build(account_id: account_id.to_s)
          open_banking_io_account.upsert_open_banking_io_snapshot!(account)
          stats[:created] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "OpenBankingIoItem::Importer - Failed to import account #{account_id}: #{e.message}"
      end

      stats
    end

    def import_transactions
      stats = { imported: 0, failed: 0 }

      open_banking_io_item.open_banking_io_accounts.joins(:account).merge(Account.visible).each do |open_banking_io_account|
        result = fetch_and_store_transactions(open_banking_io_account)
        if result[:success]
          stats[:imported] += result[:transactions_count]
        else
          stats[:failed] += 1
        end
      rescue => e
        stats[:failed] += 1
        Rails.logger.error "OpenBankingIoItem::Importer - Failed to fetch/store transactions for account #{open_banking_io_account.id}: #{e.class}"
      end

      stats
    end

    def fetch_and_store_transactions(open_banking_io_account)
      start_date = determine_sync_start_date(open_banking_io_account)
      Rails.logger.info "OpenBankingIoItem::Importer - Fetching transactions for account #{open_banking_io_account.id} from #{start_date}"

      transactions = open_banking_io_provider.get_account_transactions(
        account_id: open_banking_io_account.account_id,
        start_date: start_date
      )

      store_transactions(open_banking_io_account, transactions: Array(transactions))

      { success: true, transactions_count: Array(transactions).count }
    rescue Provider::OpenBankingIo::Error => e
      mark_requires_update! if e.error_type.in?([ :unauthorized, :access_forbidden ])
      Rails.logger.error "OpenBankingIoItem::Importer - open-banking.io API error for account #{open_banking_io_account.id}: #{e.error_type}"
      capture_sync_error("Failed to fetch transactions", e, open_banking_io_account: open_banking_io_account, error_type: e.error_type)
      { success: false, transactions_count: 0, error: I18n.t("open_banking_io_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to parse transaction response for account #{open_banking_io_account.id}: #{e.class}"
      capture_sync_error("Failed to parse open-banking.io transactions response", e, open_banking_io_account: open_banking_io_account)
      { success: false, transactions_count: 0, error: "Failed to parse response" }
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Unexpected error fetching transactions for account #{open_banking_io_account.id}: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      capture_sync_error("Unexpected error fetching transactions", e, open_banking_io_account: open_banking_io_account)
      { success: false, transactions_count: 0, error: I18n.t("open_banking_io_item.errors.transactions_failed") }
    end

    # Update-in-place (upsert-by-key) storage. Rows are keyed by their stable
    # storage key (id when present, otherwise a content hash). An incoming row
    # REPLACES the stored row with the same key, so a pending transaction that
    # settles to booked under the same id is updated rather than dropped as a
    # duplicate (which previously left the entry stuck pending forever), and a
    # re-synced pending row doesn't accumulate as a phantom duplicate.
    def store_transactions(open_banking_io_account, transactions:)
      existing_transactions = open_banking_io_account.raw_transactions_payload.to_a

      # Storage keys present in THIS fetch. A stored PENDING row whose key is not
      # in this set is a pre-auth/hold the bank stopped returning (canceled, or
      # settled under a new booked id). It must be stripped so its entry can be
      # pruned; otherwise it stays pending forever. Booked history is never
      # stripped — banks legitimately drop older booked rows from the window.
      incoming_keys = transactions.filter_map do |tx|
        next unless tx.is_a?(Hash)
        transaction_storage_key(tx).presence
      end.to_set

      merged = {}
      order = []

      add_row = lambda do |tx|
        next unless tx.is_a?(Hash)

        key = transaction_storage_key(tx)
        next if key.blank?

        order << key unless merged.key?(key)
        merged[key] = tx
      end

      existing_transactions.each do |tx|
        next unless tx.is_a?(Hash)

        key = transaction_storage_key(tx)
        next if key.blank?
        next if OpenBankingIoEntry::Processor.pending?(tx) && !incoming_keys.include?(key)

        add_row.call(tx)
      end
      incoming_count = incoming_keys.size
      transactions.each { |tx| add_row.call(tx) }

      final_transactions = order.map { |key| merged[key] }
      return if final_transactions == existing_transactions

      Rails.logger.info(
        "OpenBankingIoItem::Importer - Storing #{final_transactions.count} transactions " \
        "(#{existing_transactions.count} existing, #{incoming_count} incoming, upsert-by-key) " \
        "for account #{open_banking_io_account.account_id}"
      )
      open_banking_io_account.upsert_open_banking_io_transactions_snapshot!(final_transactions)
    end

    def transaction_storage_key(transaction)
      data = transaction.with_indifferent_access
      id = data[:id].presence
      return "id:#{id}" if id.present?

      # ISO-20022 pending entries can omit `id`. Derive a stable content hash so
      # they are stored (not dropped) and dedup idempotently across syncs.
      "hash:#{OpenBankingIoEntry::Processor.content_hash_for(data)}"
    end

    def determine_sync_start_date(open_banking_io_account)
      return open_banking_io_account.sync_start_date if open_banking_io_account.sync_start_date.present?
      return open_banking_io_item.sync_start_date if open_banking_io_item.sync_start_date.present?

      has_stored_transactions = open_banking_io_account.raw_transactions_payload.to_a.any?
      if has_stored_transactions && open_banking_io_item.last_synced_at
        open_banking_io_item.last_synced_at.to_date - 7.days
      else
        90.days.ago.to_date
      end
    end

    # Record a provider sync/import failure as a DebugLogEntry so it surfaces on
    # /settings/debug, mirroring the sibling bank-sync providers (Up, Kraken, ...).
    def capture_sync_error(message, error, open_banking_io_account: nil, error_type: nil)
      metadata = { open_banking_io_item_id: open_banking_io_item.id, error_class: error.class.name, error_message: error.message }
      metadata[:open_banking_io_account_id] = open_banking_io_account.id if open_banking_io_account
      metadata[:error_type] = error_type if error_type

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: message,
        source: self.class.name,
        provider_key: "open_banking_io",
        family: open_banking_io_item.family,
        account_provider: open_banking_io_account&.account_provider,
        metadata: metadata
      )
    end

    def mark_requires_update!
      open_banking_io_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to update item status: #{e.message}"
      capture_sync_error("Failed to mark open-banking.io item as requiring update", e)
    end

    def failed_result(error)
      { success: false, error: error, accounts_imported: 0, transactions_imported: 0 }
    end
end
