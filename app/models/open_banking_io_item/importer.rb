class OpenBankingIoItem::Importer
  # Error types that mean the connection itself needs the user's attention, not a retry:
  # expired/revoked credentials (401/403), a withdrawn or dead consent (409), and a lapsed
  # subscription (402). All of them park the item in :requires_update.
  REQUIRES_UPDATE_ERRORS = %i[unauthorized access_forbidden requires_reconnect payment_required].freeze

  attr_reader :open_banking_io_item, :open_banking_io_provider

  def initialize(open_banking_io_item, open_banking_io_provider:)
    @open_banking_io_item = open_banking_io_item
    @open_banking_io_provider = open_banking_io_provider
    @connection_needs_attention = false
  end

  def import
    @connection_needs_attention = false
    Rails.logger.info "OpenBankingIoItem::Importer - Starting import for item #{open_banking_io_item.id}"

    trigger_upstream_sync

    accounts_data = fetch_accounts_data
    return failed_result(I18n.t("open_banking_io_item.errors.accounts_fetch_failed")) unless accounts_data

    open_banking_io_item.upsert_open_banking_io_snapshot!(accounts_data)

    account_stats = import_accounts(accounts_data)
    transaction_stats = import_transactions

    # Connection health comes from the accounts we just fetched, not from whether this
    # particular run happened to hit an error. `needsReconnect` is the service's durable
    # per-account flag (an expired PSD2 consent sets it and it stays set until the user
    # reconnects), so deriving from it is idempotent -- whereas the transient sync_all
    # failures made the badge flap between good and requires_update run to run.
    if accounts_needing_reconnect?
      mark_requires_update!
    elsif account_stats[:failed].zero? && !@connection_needs_attention
      clear_requires_update!
    end

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
  ensure
    # The client holds one keep-alive socket for the whole import. Release it here rather
    # than leaving it open until the memoized provider is garbage collected.
    open_banking_io_provider.try(:close)
  end

  # Accounts-only refresh for the interactive linking screens. Same path as #import's
  # discovery step -- including its index_by preload and a wrapping transaction -- so the
  # controller does not need its own copy that saves once per account.
  def refresh_accounts_only
    @connection_needs_attention = false
    accounts_data = fetch_accounts_data
    raise Provider::OpenBankingIo::Error.new(I18n.t("open_banking_io_item.errors.accounts_fetch_failed"), :fetch_failed) unless accounts_data

    ActiveRecord::Base.transaction do
      open_banking_io_item.upsert_open_banking_io_snapshot!(accounts_data)
      import_accounts(accounts_data)
    end
  ensure
    open_banking_io_provider.try(:close)
  end

  private

    # Best-effort: ask open-banking.io to pull fresh data from the upstream banks
    # BEFORE we paginate, so `get_accounts`/`get_transactions` read refreshed data
    # instead of re-importing a stale cached window. A sync failure (e.g. an
    # account whose bank session expired) must never abort importing the cached
    # data we already have, so it is swallowed and surfaced via DebugLogEntry.
    def trigger_upstream_sync
      result = open_banking_io_provider.sync_all
      report_upstream_sync_failures(result)
      result
    rescue Provider::OpenBankingIo::Error => e
      mark_requires_update! if e.error_type.in?(REQUIRES_UPDATE_ERRORS)
      Rails.logger.error "OpenBankingIoItem::Importer - Upstream sync failed (continuing with cached data): #{e.error_type}"
      capture_sync_error("Failed to trigger upstream open-banking.io sync", e, error_type: e.error_type)
      nil
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Upstream sync failed (continuing with cached data): #{e.class}"
      capture_sync_error("Failed to trigger upstream open-banking.io sync", e)
      nil
    end

    # POST api/sync answers 200 even when individual accounts failed, so a connection where
    # 3 of 5 accounts need reconnecting used to read as complete success.
    def report_upstream_sync_failures(result)
      failures = Array(result.try(:failures))
      return if failures.empty?

      failures.each do |failure|
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "open-banking.io upstream sync failed for one account",
          source: self.class.name,
          provider_key: "open_banking_io",
          family: open_banking_io_item.family,
          metadata: {
            open_banking_io_item_id: open_banking_io_item.id,
            provider_account_id: failure[:account_id],
            reason: failure[:reason],
            bank_error_code: failure[:bank_error_code]
          }.compact
        )
      end

      # reconnect_needed is exactly the condition the item status exists to represent.
      mark_requires_update! if failures.any? { |f| f[:reason].to_s == "reconnect_needed" }
    end

    def fetch_accounts_data
      items = open_banking_io_provider.get_accounts
      { items: items }
    rescue Provider::OpenBankingIo::Error => e
      mark_requires_update! if e.error_type.in?(REQUIRES_UPDATE_ERRORS)
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
        # e.message is deliberately not logged: this rescue wraps snapshot writes over
        # decrypted account data. capture_sync_error records the class and puts the message
        # in DebugLogEntry metadata, where support can see it behind admin auth.
        capture_sync_error("Failed to import an open-banking.io account", e, provider_account_id: account_id)
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

          # The rate limit is per API key, so once one account trips it every remaining
          # account trips it too -- each burning its own retry budget for nothing.
          if result[:error_type] == :rate_limited
            Rails.logger.warn "OpenBankingIoItem::Importer - Rate limited; skipping the remaining accounts this run"
            stats[:aborted] = true
            break
          end
        end
      rescue => e
        stats[:failed] += 1
        capture_sync_error("Failed to fetch or store open-banking.io transactions", e, open_banking_io_account: open_banking_io_account)
      end

      stats
    end

    def fetch_and_store_transactions(open_banking_io_account)
      start_date = determine_sync_start_date(open_banking_io_account)
      request_backfill(open_banking_io_account, start_date)
      Rails.logger.info "OpenBankingIoItem::Importer - Fetching transactions for account #{open_banking_io_account.id} from #{start_date}"

      transactions = open_banking_io_provider.get_account_transactions(
        account_id: open_banking_io_account.account_id,
        start_date: start_date
      )

      store_transactions(open_banking_io_account, transactions: Array(transactions))

      { success: true, transactions_count: Array(transactions).count }
    rescue Provider::OpenBankingIo::Error => e
      mark_requires_update! if e.error_type.in?(REQUIRES_UPDATE_ERRORS)
      Rails.logger.error "OpenBankingIoItem::Importer - open-banking.io API error for account #{open_banking_io_account.id}: #{e.error_type}"
      capture_sync_error("Failed to fetch transactions", e, open_banking_io_account: open_banking_io_account, error_type: e.error_type)
      { success: false, transactions_count: 0, error_type: e.error_type, error: I18n.t("open_banking_io_item.errors.transactions_failed") }
    rescue JSON::ParserError => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to parse transaction response for account #{open_banking_io_account.id}: #{e.class}"
      capture_sync_error("Failed to parse open-banking.io transactions response", e, open_banking_io_account: open_banking_io_account)
      { success: false, transactions_count: 0, error: I18n.t("open_banking_io_item.errors.transactions_failed") }
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

      # A fetch that came back empty tells us nothing about which pendings are still live,
      # so it must not be read as "the bank dropped them all". Mirrors the replace_pending
      # flag in AkahuItem::Importer.
      replace_pending = transactions.any?

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
        next if replace_pending && OpenBankingIoEntry::Processor.pending?(tx) && !incoming_keys.include?(key)

        add_row.call(tx)
      end
      incoming_count = incoming_keys.size
      transactions.each { |tx| add_row.call(tx) }

      # Normalise before comparing: rows read back from the encrypted JSONB column are
      # string-keyed while incoming rows from the provider are symbol-keyed, so the guard
      # was always false and every sync re-serialised, re-encrypted and rewrote the whole
      # (multi-MB) blob even when nothing had changed.
      final_transactions = order.map { |key| merged[key].deep_stringify_keys }
      return if final_transactions == existing_transactions.map { |tx| tx.is_a?(Hash) ? tx.deep_stringify_keys : tx }

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

    # An explicitly configured sync_start_date is a backfill request, and the server only
    # advances its own incremental cursor unless asked otherwise -- so filtering the read by
    # start_date returned nothing for history the service had never fetched from the bank.
    # Best-effort: a bank that refuses the window must not fail the whole import.
    def request_backfill(open_banking_io_account, start_date)
      return if configured_sync_start_date(open_banking_io_account).blank?
      # Initial sync only -- see determine_sync_start_date.
      return if open_banking_io_account.raw_transactions_payload.to_a.any?

      result = open_banking_io_provider.sync(open_banking_io_account.account_id, from_date: start_date)
      served = result.try(:served_from_date)
      if served.present? && Date.parse(served.to_s) > start_date
        Rails.logger.info(
          "OpenBankingIoItem::Importer - Bank served from #{served}, not the requested #{start_date}, " \
          "for account #{open_banking_io_account.id}"
        )
      end
    rescue => e
      Rails.logger.warn "OpenBankingIoItem::Importer - Backfill request failed for account #{open_banking_io_account.id}: #{e.class}"
      capture_sync_error("Failed to request open-banking.io backfill", e, open_banking_io_account: open_banking_io_account)
    end

    def configured_sync_start_date(_open_banking_io_account)
      open_banking_io_item.sync_start_date.presence
    end

    def determine_sync_start_date(open_banking_io_account)
      stored = open_banking_io_account.raw_transactions_payload.to_a

      # The configured start date is a BACKFILL request, so it applies to the initial sync
      # only. Returning it unconditionally made every later sync re-fetch, re-paginate and
      # re-decrypt the entire history forever -- and on a large account that eventually
      # crosses the pagination cap into a permanent hard failure. Matches how
      # EnableBankingItem::Importer and MercuryItem::Importer gate theirs.
      if stored.empty?
        configured = configured_sync_start_date(open_banking_io_account)
        return configured if configured.present?
      end

      return 90.days.ago.to_date if stored.empty? || open_banking_io_item.last_synced_at.blank?

      # A stored pending row must stay inside the window: fall out of it and the row is
      # stripped from storage and its entry pruned, even though the pre-auth is still live.
      # EU hotel/car-hire/fuel holds routinely outlive a 7-day window.
      lookback = stored.any? { |tx| tx.is_a?(Hash) && OpenBankingIoEntry::Processor.pending?(tx) } ? 30.days : 7.days
      open_banking_io_item.last_synced_at.to_date - lookback
    end

    # Record a provider sync/import failure as a DebugLogEntry so it surfaces on
    # /settings/debug, mirroring the sibling bank-sync providers (Up, Kraken, ...).
    def capture_sync_error(message, error, open_banking_io_account: nil, error_type: nil, **extra)
      metadata = { open_banking_io_item_id: open_banking_io_item.id, error_class: error.class.name, error_message: error.message }
      metadata[:open_banking_io_account_id] = open_banking_io_account.id if open_banking_io_account
      metadata[:error_type] = error_type if error_type
      metadata.merge!(extra.compact)

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

    # Any linked-or-not provider account the service says needs reconnecting. Reads the
    # snapshot column just written by import_accounts, so it reflects this fetch.
    def accounts_needing_reconnect?
      open_banking_io_item.open_banking_io_accounts.reload.any? { |a| a.account_status == "requires_update" }
    end

    def clear_requires_update!
      return unless open_banking_io_item.requires_update?

      open_banking_io_item.update!(status: :good)
    rescue => e
      capture_sync_error("Failed to clear the open-banking.io requires_update status", e)
    end

    def mark_requires_update!
      # Remember it for this run: the rest of the import can still succeed, and
      # clear_requires_update! must not then undo the flag we just raised.
      @connection_needs_attention = true
      open_banking_io_item.update!(status: :requires_update)
    rescue => e
      Rails.logger.error "OpenBankingIoItem::Importer - Failed to update item status: #{e.message}"
      capture_sync_error("Failed to mark open-banking.io item as requiring update", e)
    end

    # Must mirror the success shape from #import. `accounts_imported` appeared nowhere else
    # in the codebase, so Syncer#errors_from_result only worked because :error is read first.
    def failed_result(error, error_type: nil)
      {
        success: false,
        error: error,
        error_type: error_type,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }.compact
    end
end
