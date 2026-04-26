class GocardlessItem::Importer
  attr_reader :gocardless_item, :client

  def initialize(gocardless_item, client:)
    @gocardless_item = gocardless_item
    @client          = client
  end

  # Fetches raw data from the GoCardless API and stores it on each GocardlessAccount.
  # Does NOT create Account entries — that is handled by GocardlessAccount::Processor
  # during the process phase (called separately from GocardlessItem::Syncer).
  def import
    unless gocardless_item.bank_connected?
      gocardless_item.update!(status: :requires_update)
      return { success: false, error: "Bank connection expired — please reconnect", accounts_updated: 0, transactions_imported: 0 }
    end

    accounts_updated      = 0
    accounts_failed       = 0
    transactions_imported = 0

    gocardless_item.gocardless_accounts.active.each do |gc_account|
      begin
        # Balance fetch is best-effort — some banks (e.g. Monzo) return errors on
        # this endpoint intermittently. A stale balance is preferable to a failed sync.
        begin
          fetch_and_store_balance(gc_account)
        rescue Provider::Gocardless::AuthError
          raise  # Re-raise auth errors so the outer rescue can mark status
        rescue Provider::Gocardless::RateLimitError
          raise  # Re-raise so the outer rescue aborts the whole sync cleanly
        rescue => e
          Rails.logger.warn "GocardlessItem::Importer - Balance fetch failed for gocardless_account #{gc_account.id} (#{e.class}: #{e.message}); continuing with stale balance"
        end

        count = fetch_and_store_transactions(gc_account)
        transactions_imported += count
        accounts_updated      += 1
      rescue Provider::Gocardless::RateLimitError => e
        # Rate limit hit — abort the entire import so the job fails cleanly and
        # Sidekiq's exponential backoff retries after a meaningful delay.
        Rails.logger.warn "GocardlessItem::Importer - Rate limited by GoCardless; aborting sync to avoid retry spiral"
        raise
      rescue Provider::Gocardless::AuthError
        gocardless_item.update!(status: :requires_update)
        accounts_failed += 1
        Rails.logger.error "GocardlessItem::Importer - Auth error for gocardless_account #{gc_account.id}; marked item for reconnect"
      rescue Provider::Gocardless::ApiError => e
        accounts_failed += 1
        Rails.logger.error "GocardlessItem::Importer - API error for gocardless_account #{gc_account.id}: #{e.message}"
      rescue => e
        accounts_failed += 1
        Rails.logger.error "GocardlessItem::Importer - Unexpected error for gocardless_account #{gc_account.id}: #{e.class} - #{e.message}"
      end
    end

    success = accounts_failed == 0
    result  = {
      success:               success,
      accounts_updated:      accounts_updated,
      accounts_failed:       accounts_failed,
      transactions_imported: transactions_imported
    }
    result[:error] = "Some accounts failed to sync" unless success
    result
  end

  private

    def fetch_and_store_balance(gc_account)
      data     = client.balances(gc_account.account_id)
      balances = data["balances"] || []
      return if balances.empty?

      bal = balances.find { |b| b["balanceType"] == "interimAvailable" } ||
            balances.find { |b| b["balanceType"] == "closingBooked" } ||
            balances.first

      return unless bal

      amount   = bal.dig("balanceAmount", "amount").to_d
      currency = bal.dig("balanceAmount", "currency").presence || gc_account.currency

      gc_account.update!(current_balance: amount, currency: currency)
    end

    def fetch_and_store_transactions(gc_account)
      start_date = determine_start_date(gc_account)
      data       = client.transactions(gc_account.account_id, date_from: start_date)

      booked  = data.dig("transactions", "booked")  || []
      pending = data.dig("transactions", "pending") || []

      booked  = filter_by_date(booked, start_date)
      pending = filter_by_date(pending, start_date)

      booked  = deduplicate_api_response(booked)
      pending = deduplicate_api_response(pending)

      # Tag pending transactions so the Entry processor and ProviderImportAdapter
      # can identify them for reconciliation when the posted version arrives.
      pending = pending.map { |t| t.merge("_pending" => true) }

      # Remove any stored pending entries that have now settled as a booked transaction
      # (matched by transactionId or by internalTransactionId).
      # internalTransactionId is always unique; transactionId can collide across accounts
      booked_ids = booked.map { |t|
        t["internalTransactionId"].presence || t["transactionId"].presence
      }.compact.to_set

      existing_payload = gc_account.raw_transactions_payload.to_a

      # Drop stale pending entries that are now booked
      existing_payload.reject! do |t|
        t["_pending"] && (booked_ids.include?(t["internalTransactionId"].to_s.presence) ||
                          booked_ids.include?(t["transactionId"].to_s.presence))
      end

      existing_ids = existing_payload.map { |t|
        (t["internalTransactionId"] || t[:internalTransactionId]).presence ||
          (t["transactionId"] || t[:transactionId]).presence
      }.compact.to_set

      new_booked = booked.reject do |txn|
        id = txn["internalTransactionId"].presence || txn["transactionId"].presence
        id.present? && existing_ids.include?(id)
      end

      # For pending, always replace with the freshest set (pending statuses change rapidly)
      existing_payload.reject! { |t| t["_pending"] }
      new_transactions = new_booked + pending

      combined = filter_by_date(existing_payload + new_transactions, start_date)

      if combined.length != existing_payload.length || new_transactions.any?
        gc_account.update!(raw_transactions_payload: combined)
      end

      new_booked.count
    end

    def filter_by_date(transactions, start_date)
      return transactions unless start_date

      transactions.reject do |txn|
        date_str = txn["bookingDate"] || txn["valueDate"]
        next false if date_str.blank?

        begin
          Date.parse(date_str.to_s) < start_date
        rescue ArgumentError
          false
        end
      end
    end

    def deduplicate_api_response(transactions)
      seen       = {}
      duplicates = 0

      result = transactions.select do |txn|
        key = build_content_key(txn)
        if seen[key]
          duplicates += 1
          false
        else
          seen[key] = true
          true
        end
      end

      if duplicates > 0
        Rails.logger.info "GocardlessItem::Importer - Removed #{duplicates} content-level duplicate(s) from API response"
      end

      result
    end

    def build_content_key(txn)
      [
        txn["transactionId"],
        txn["internalTransactionId"],
        txn["bookingDate"] || txn["valueDate"],
        txn.dig("transactionAmount", "amount"),
        txn.dig("transactionAmount", "currency"),
        txn["creditorName"] || txn["debtorName"],
        txn["remittanceInformationUnstructured"]
      ].map(&:to_s).join("\x1F")
    end

    def determine_start_date(gc_account)
      # Use persisted entries (not raw_transactions_payload) to distinguish initial
      # vs incremental — raw payload is written even on failed sync attempts.
      account = gc_account.current_account
      has_synced_entries = account&.entries&.where(source: "gocardless")&.exists? || false

      if has_synced_entries
        7.days.ago.to_date
      else
        gocardless_item.sync_start_date&.to_date || 90.days.ago.to_date
      end
    end
end
