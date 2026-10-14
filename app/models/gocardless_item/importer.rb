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

    # Update raw payload on the item
    gocardless_item.upsert_gocardless_snapshot!(stats)
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

      account_ids = Array(requisition[:accounts]).map(&:to_s).reject(&:blank?)

      if account_ids.empty?
        Rails.logger.info "GocardlessItem::Importer - Requisition #{requisition[:status]} with no accounts yet"
        stats["total_accounts"] = 0
        persist_stats!
        return
      end

      stats["total_accounts"] = account_ids.size
      upstream_account_ids = []

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
          else
            Rails.logger.error "GocardlessItem::Importer - Failed to import account #{account_id}: #{e.message}"
            stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
            register_error(e, account_data: { account_id: account_id })
          end
        rescue => e
          Rails.logger.error "GocardlessItem::Importer - Failed to import account #{account_id}: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: { account_id: account_id })
        end
      end

      persist_stats!

      prune_removed_accounts(account_ids)
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

        if transactions_data.any?
          # Convert SDK objects to hashes and merge with existing
          transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(gocardless_account.raw_transactions_payload || [], transactions_hashes)
          gocardless_account.upsert_gocardless_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue => e
        Rails.logger.warn "GocardlessItem::Importer - Failed to fetch transactions: #{e.message}"
        register_error(e, context: "transactions", account_id: gocardless_account.id)
      end
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

    def merge_transactions(existing, new_transactions)
      # Merge by ID, preferring newer data
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    # Identity of a transaction for snapshot de-duplication.
    #
    # The generated default looked for :id, :date, :amount and :description. GoCardless
    # uses none of those names, so EVERY transaction produced the same key ("--") and the
    # merge collapsed a whole statement into a single row: 170 transactions stored as 1.
    # Mirrors GocardlessAccount::Transactions::Processor#external_id_for so the snapshot
    # and the imported entries agree on what counts as the same transaction.
    def transaction_key(transaction)
      t = transaction.is_a?(Hash) ? transaction.with_indifferent_access : transaction

      t[:transactionId].presence || t[:internalTransactionId].presence ||
        [
          t[:bookingDate] || t[:valueDate],
          t.dig(:transactionAmount, :amount),
          t[:remittanceInformationUnstructured]
        ].join("|")
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
