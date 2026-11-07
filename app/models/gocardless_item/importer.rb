# frozen_string_literal: true

class GocardlessItem::Importer
  include SyncStats::Collector
  include GocardlessAccount::DataHelpers

  attr_reader :gocardless_item, :gocardless_provider, :sync

  def initialize(gocardless_item, gocardless_provider:, sync: nil)
    @gocardless_item = gocardless_item
    @gocardless_provider = gocardless_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def import
    Rails.logger.info "GocardlessItem::Importer - Starting import for item #{gocardless_item.id}"

    credentials = gocardless_item.gocardless_credentials
    unless credentials
      raise CredentialsError, "No Gocardless credentials configured for item #{gocardless_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch data
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    linked_accounts = GocardlessAccount
      .where(gocardless_item_id: gocardless_item.id)
      .joins(:account_provider)

    Rails.logger.info "GocardlessItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |gocardless_account|
      Rails.logger.info "GocardlessItem::Importer - Processing linked account #{gocardless_account.id}"
      import_account_data(gocardless_account, credentials)
    end

    persist_stats!

    # Update raw payload on the item
    gocardless_item.upsert_gocardless_snapshot!(stats)

    # Raised only after every account has been tried and the stats saved, so one failing
    # account does not starve the others, yet the sync still fails and the cursor holds.
    raise @transaction_failure if @transaction_failure
  rescue Provider::Gocardless::AuthenticationError => e
    gocardless_item.update!(status: :requires_update)
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

    def import_accounts(credentials)
      Rails.logger.info "GocardlessItem::Importer - Fetching accounts"

      # A requisition holds the user's consent and only lists account ids once the user
      # has finished authorising at the bank (status LN). Anything else means the
      # connection is not usable yet, and is not an error worth failing the sync over.
      requisition = gocardless_provider.get_requisition(
        requisition_id: gocardless_item.requisition_id
      )
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      gocardless_item.update(requisition_status: requisition[:status])

      if requisition[:status].to_s == "EX"
        gocardless_item.update!(status: :requires_update)
        raise Provider::Gocardless::AuthenticationError.new("GoCardless consent has expired; reconnect the bank", :consent_expired)
      end

      account_ids = Array(requisition[:accounts]).map(&:to_s).reject(&:blank?)

      if account_ids.empty?
        Rails.logger.info "GocardlessItem::Importer - Requisition #{requisition[:status]} with no accounts yet"
        stats["total_accounts"] = 0
        persist_stats!
        return
      end

      stats["total_accounts"] = account_ids.size
      @requisition_account_ids = account_ids
      upstream_account_ids = []
      fetch_failed = false

      account_ids.each do |account_id|
        begin
          import_account(account_id, credentials)
          upstream_account_ids << account_id
        rescue Provider::Gocardless::GocardlessError => e
          # A rate-limited account is a normal daily condition, not a broken one. Keep it
          # in upstream_account_ids so the pruner does not delete an account that is
          # merely quota-blocked today.
          if e.rate_limited?
            Rails.logger.info "GocardlessItem::Importer - Account #{account_id} rate limited, skipping until quota resets"
            stats["accounts_rate_limited"] = stats.fetch("accounts_rate_limited", 0) + 1
            upstream_account_ids << account_id
            fetch_failed = true
          else
            Rails.logger.error "GocardlessItem::Importer - Failed to import account #{account_id}: #{e.message}"
            fetch_failed = true
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            register_error(e, account_data: { account_id: account_id })
          end
        rescue => e
          fetch_failed = true
          Rails.logger.error "GocardlessItem::Importer - Failed to import account #{account_id}: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: { account_id: account_id })
        end
      end

      persist_stats!

      # A partial fetch is not proof the other accounts are gone.
      prune_removed_accounts(account_ids) unless fetch_failed
    end

    # GoCardless splits one account across three endpoints, and each call is charged
    # against a small per-account daily quota, so they are fetched once here and stitched
    # into a single payload rather than re-fetched per consumer.
    def import_account(account_id, credentials)
      return if account_id.blank?

      metadata = gocardless_provider.get_account(account_id: account_id)
      details = gocardless_provider.get_account_details(account_id: account_id)
      balances = gocardless_provider.get_account_balances(account_id: account_id)
      stats["api_requests"] = stats.fetch("api_requests", 0) + 3

      account_data = {
        id: account_id,
        institution_id: metadata[:institution_id],
        iban: metadata[:iban],
        status: metadata[:status],
        owner_name: metadata[:owner_name],
        details: details[:account] || {},
        balances: Array(balances[:balances])
      }

      gocardless_account = gocardless_item.gocardless_accounts.find_or_initialize_by(
        gocardless_account_id: account_id
      )
      if gocardless_account.new_record? && (reissued = reissued_account_for(account_data))
        reissued.gocardless_account_id = account_id
        gocardless_account = reissued
      end

      gocardless_account.upsert_from_gocardless!(account_data)

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_account_data(gocardless_account, credentials)
      # Import transactions
      import_transactions(gocardless_account, credentials)
    end

    def import_transactions(gocardless_account, credentials)
      Rails.logger.info "GocardlessItem::Importer - Fetching transactions for account #{gocardless_account.id}"

      begin
        # Determine date range
        start_date = calculate_transaction_start_date(gocardless_account)
        end_date = Date.current

        response = gocardless_provider.get_account_transactions(
          account_id: gocardless_account.gocardless_account_id,
          date_from: start_date,
          date_to: end_date
        )

        # GoCardless returns booked and pending separately. Both are kept, tagged so the
        # processor can mark pending entries, because a pending transaction becomes a
        # booked one later and must reconcile rather than duplicate.
        booked = Array(response.dig(:transactions, :booked)).map { |t| t.merge(pending: false) }
        pending = Array(response.dig(:transactions, :pending)).map { |t| t.merge(pending: true) }
        transactions_data = booked + pending

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        # Reconcile even an empty response: a covered pending hold that is no longer
        # returned has been cancelled and must leave the snapshot.
        existing = gocardless_account.raw_transactions_payload || []
        transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
        merged = merge_transactions(existing, transactions_hashes, covered_from: start_date)
        gocardless_account.upsert_gocardless_transactions_snapshot!(merged) if merged != existing
        stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size if transactions_data.any?
      rescue Provider::Gocardless::GocardlessError => e
        if e.rate_limited?
          # Daily quota is a normal condition; the next sync's window overlaps this one.
          Rails.logger.info "GocardlessItem::Importer - Transactions for account #{gocardless_account.id} rate limited"
          register_error(e, context: "transactions", account_id: gocardless_account.id)
        else
          record_transaction_failure(gocardless_account, e)
        end
      rescue => e
        record_transaction_failure(gocardless_account, e)
      end
    end

    # Swallowing a failed fetch would let the sync succeed and advance last_synced_at, so
    # anything that outlasts the incremental overlap window is never requested again.
    def record_transaction_failure(gocardless_account, error)
      Rails.logger.warn "GocardlessItem::Importer - Failed to fetch transactions: #{error.message}"
      register_error(error, context: "transactions", account_id: gocardless_account.id)

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "GoCardless transaction fetch failed: #{error.message}",
        source: self.class.name,
        provider_key: "gocardless",
        family: gocardless_item.family,
        account_provider: gocardless_account.account_provider,
        metadata: { gocardless_item_id: gocardless_item.id, gocardless_account_id: gocardless_account.id, error_class: error.class.name }
      )

      @transaction_failure ||= error
    end

    def calculate_transaction_start_date(gocardless_account)
      # Use user-specified start date if available
      user_start = gocardless_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing transactions, use incremental sync
      existing_count = (gocardless_account.raw_transactions_payload || []).size
      if existing_count >= 10 && gocardless_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch updates
        (gocardless_item.last_synced_at - 7.days).to_date
      else
        # Full sync: go back 90 days
        90.days.ago.to_date
      end
    end

    # Merge by identity, preferring newer data. A pending hold inside the fetched window
    # that the bank no longer returns was cancelled (a posted one comes back as booked),
    # so it is dropped; pending rows older than the window are left alone.
    def merge_transactions(existing, new_transactions, covered_from: nil)
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_keys = new_transactions.map { |t| transaction_key(t) }
      if covered_from
        by_id.delete_if { |key, t| !new_keys.include?(key) && cancelled_pending?(t, covered_from) }
      end
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def cancelled_pending?(transaction, covered_from)
      data = transaction.with_indifferent_access
      return false unless data[:pending]

      date = parse_date(data[:bookingDate] || data[:valueDate] || data[:bookingDateTime] || data[:valueDateTime])
      date.present? && date >= covered_from
    end

    # Identity of a transaction for snapshot de-duplication, shared with the
    # transactions processor. The generated default looked for names GoCardless does not
    # use, so every transaction got the same key and a statement collapsed into one row.
    def transaction_key(transaction)
      transaction_identity(transaction)
    end

    # A new consent can reissue account ids for the same bank account. Matching on IBAN
    # moves the existing record (and its linked account and history) onto the new id,
    # instead of creating a duplicate and pruning the original.
    def reissued_account_for(account_data)
      iban = account_data[:iban].presence || account_data.dig(:details, :iban).presence
      return if iban.blank?

      gocardless_item.gocardless_accounts
        .where.not(gocardless_account_id: @requisition_account_ids)
        .where("raw_payload->>'iban' = :iban OR raw_payload->'details'->>'iban' = :iban", iban: iban.to_s)
        .first
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = gocardless_item.gocardless_accounts
        .where.not(gocardless_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "GocardlessItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
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
