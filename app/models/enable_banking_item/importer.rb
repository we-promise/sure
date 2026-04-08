class EnableBankingItem::Importer
  # Maximum number of pagination requests to prevent infinite loops
  # Enable Banking typically returns ~100 transactions per page, so 100 pages = ~10,000 transactions
  MAX_PAGINATION_PAGES = 100

  attr_reader :enable_banking_item, :enable_banking_provider

  def initialize(enable_banking_item, enable_banking_provider:)
    @enable_banking_item = enable_banking_item
    @enable_banking_provider = enable_banking_provider
  end

  def import
    unless enable_banking_item.session_valid?
      enable_banking_item.update!(status: :requires_update)
      return { success: false, error: "Session expired or invalid", accounts_updated: 0, transactions_imported: 0 }
    end

    session_data = fetch_session_data
    unless session_data
      error_msg = @session_error || "Failed to fetch session data"
      return { success: false, error: error_msg, accounts_updated: 0, transactions_imported: 0 }
    end

    # Store raw payload
    begin
      enable_banking_item.upsert_enable_banking_snapshot!(session_data)
    rescue => e
      Rails.logger.error "EnableBankingItem::Importer - Failed to store session snapshot: #{e.message}"
    end

    sync_uids_from_accounts_data(session_data[:accounts])

    # Update accounts from session
    accounts_updated = 0
    accounts_failed = 0

    if session_data[:accounts].present?
      existing_uids = enable_banking_item.enable_banking_accounts
                                         .joins(:account_provider)
                                         .pluck(:uid)
                                         .map(&:to_s)

      # Enable Banking API returns accounts as an array of UIDs (strings) in the session response
      # We need to handle both array of strings and array of hashes
      session_data[:accounts].each do |account_data|
        # Handle both string UIDs and hash objects
        # Use identification_hash as the stable identifier across sessions
        uid = if account_data.is_a?(String)
          account_data
        elsif account_data.is_a?(Hash)
          (account_data[:identification_hash] || account_data[:uid] || account_data["identification_hash"] || account_data["uid"])&.to_s
        else
          nil
        end

        next unless uid.present?

        # Only update if this account was previously linked
        next unless existing_uids.include?(uid)

        begin
          # For string UIDs, we don't have account data to update - skip the import_account call
          # The account data will be fetched via balances/transactions endpoints
          if account_data.is_a?(Hash)
            import_account(account_data)
            accounts_updated += 1
          end
        rescue => e
          accounts_failed += 1
          Rails.logger.error "EnableBankingItem::Importer - Failed to update account #{uid}: #{e.message}"
        end
      end
    end

    # Fetch balances and transactions for linked accounts
    transactions_imported = 0
    transactions_failed = 0

    linked_accounts_query = enable_banking_item.enable_banking_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    linked_accounts_query.each do |enable_banking_account|
      begin
        fetch_and_update_balance(enable_banking_account)

        result = fetch_and_store_transactions(enable_banking_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "EnableBankingItem::Importer - Failed to process account #{enable_banking_account.uid}: #{e.message}"
      end
    end

    result = {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_updated: accounts_updated,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed
    }
    if !result[:success] && (accounts_failed > 0 || transactions_failed > 0)
      parts = []
      parts << "#{accounts_failed} #{'account'.pluralize(accounts_failed)} failed" if accounts_failed > 0
      parts << "#{transactions_failed} #{'transaction'.pluralize(transactions_failed)} failed" if transactions_failed > 0
      result[:error] = parts.join(", ")
    end
    result
  end

  private

    def extract_friendly_error_message(exception)
      [ exception, exception.cause ].compact.each do |ex|
        case ex
        when SocketError then return "DNS resolution failed: check your network/DNS configuration"
        when Net::OpenTimeout, Net::ReadTimeout then return "Connection timed out: the Enable Banking API may be unreachable"
        when Errno::ECONNREFUSED then return "Connection refused: the Enable Banking API is unreachable"
        end
      end

      msg = exception.message.to_s
      return "DNS resolution failed: check your network/DNS configuration" if msg.include?("getaddrinfo") || msg.match?(/name or service not known/i)
      return "Connection timed out: the Enable Banking API may be unreachable" if msg.include?("execution expired") || msg.include?("timeout") || msg.match?(/timed out/i)
      return "Connection refused: the Enable Banking API is unreachable" if msg.include?("ECONNREFUSED") || msg.match?(/connection refused/i)

      msg
    end

    def fetch_session_data
      enable_banking_provider.get_session(session_id: enable_banking_item.session_id)
    rescue Provider::EnableBanking::EnableBankingError => e
      if e.error_type == :unauthorized || e.error_type == :not_found
        enable_banking_item.update!(status: :requires_update)
      end
      Rails.logger.error "EnableBankingItem::Importer - Enable Banking API error: #{e.message}"
      @session_error = extract_friendly_error_message(e)
      nil
    rescue => e
      Rails.logger.error "EnableBankingItem::Importer - Unexpected error fetching session: #{e.class} - #{e.message}"
      @session_error = extract_friendly_error_message(e)
      nil
    end

    def import_account(account_data)
      # Use identification_hash as the stable identifier across sessions
      uid = account_data[:identification_hash] || account_data[:uid]

      enable_banking_account = find_enable_banking_account_by_hash(uid)
      return unless enable_banking_account

      enable_banking_account.upsert_enable_banking_snapshot!(account_data)
      enable_banking_account.save!
    end

    def fetch_and_update_balance(enable_banking_account)
      balance_data = enable_banking_provider.get_account_balances(
        account_id: enable_banking_account.api_account_id,
        psu_headers: enable_banking_item.build_psu_headers
      )

      # Enable Banking returns an array of balances
      balances = balance_data[:balances] || []
      return if balances.empty?

      # Find the most relevant balance (prefer "ITAV" or "CLAV" types)
      balance = balances.find { |b| b[:balance_type] == "ITAV" } ||
                balances.find { |b| b[:balance_type] == "CLAV" } ||
                balances.find { |b| b[:balance_type] == "ITBD" } ||
                balances.find { |b| b[:balance_type] == "CLBD" } ||
                balances.first

      if balance.present?
        amount = balance.dig(:balance_amount, :amount) || balance[:amount]
        currency = balance.dig(:balance_amount, :currency) || balance[:currency]

        if amount.present?
          indicator = balance[:credit_debit_indicator]
          parsed_amount = amount.to_d
          parsed_amount = -parsed_amount if indicator == "DBIT"

          enable_banking_account.update!(
            current_balance: parsed_amount,
            currency: currency.presence || enable_banking_account.currency
          )
        end
      end
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "EnableBankingItem::Importer - Error fetching balance for account #{enable_banking_account.uid}: #{e.message}"
    end

    def fetch_and_store_transactions(enable_banking_account)
      start_date = determine_sync_start_date(enable_banking_account)

      all_transactions = fetch_paginated_transactions(
        enable_banking_account,
        start_date: start_date,
        transaction_status: "BOOK",
        psu_headers: enable_banking_item.build_psu_headers
      )

      # Also fetch pending transactions (visible for 1-3 days before they become BOOK)
      pending_transactions = fetch_paginated_transactions(
        enable_banking_account,
        start_date: start_date,
        transaction_status: "PDNG",
        psu_headers: enable_banking_item.build_psu_headers
      )

      book_ids = all_transactions
        .map { |tx| tx.with_indifferent_access[:transaction_id].presence }
        .compact.to_set

      book_entry_refs = all_transactions
        .select { |tx| tx.with_indifferent_access[:transaction_id].blank? }
        .map { |tx| tx.with_indifferent_access[:entry_reference].presence }
        .compact.to_set

      pending_transactions.reject! do |tx|
        tx = tx.with_indifferent_access
        tx[:transaction_id].present? ? book_ids.include?(tx[:transaction_id]) : book_entry_refs.include?(tx[:entry_reference].presence)
      end

      all_transactions = all_transactions + tag_as_pending(pending_transactions)

      # Deduplicate API response: Enable Banking sometimes returns the same logical
      # transaction with different entry_reference IDs in the same response.
      # Remove content-level duplicates before storing. (Issue #954)
      all_transactions = deduplicate_api_transactions(all_transactions)

      # Post-fetch safety filter: some ASPSPs ignore date_from or return extra transactions
      all_transactions = filter_transactions_by_date(all_transactions, start_date)

      transactions_count = all_transactions.count

      if all_transactions.any?
        existing_transactions = enable_banking_account.raw_transactions_payload.to_a

        # C4: Remove stored PDNG entries that have now settled as BOOK.
        # When a BOOK transaction arrives with the same transaction_id as a stored
        # PDNG entry, the pending entry is stale — drop it to avoid duplicates.
        book_ids = all_transactions
          .reject { |tx| tx.with_indifferent_access[:_pending] }
          .map { |tx| tx.with_indifferent_access[:transaction_id].presence }
          .compact.to_set

        # Fallback: collect entry_references for BOOK rows that have no transaction_id
        book_entry_refs = all_transactions
          .reject { |tx| tx.with_indifferent_access[:_pending] }
          .map { |tx| tx.with_indifferent_access[:entry_reference].presence }
          .compact.to_set

        removed_pending = existing_transactions.reject! do |tx|
          tx = tx.with_indifferent_access
          pending_flag = tx.dig(:extra, :enable_banking, :pending) || tx[:_pending]
          next false unless pending_flag
          tx[:transaction_id].present? ? book_ids.include?(tx[:transaction_id]) : book_entry_refs.include?(tx[:entry_reference].presence)
        end

        existing_ids = existing_transactions.map { |tx|
          tx = tx.with_indifferent_access
          tx[:transaction_id].presence || tx[:entry_reference].presence
        }.compact.to_set

        new_transactions = all_transactions.select do |tx|
          # Use transaction_id if present, otherwise fall back to entry_reference
          tx_id = tx[:transaction_id].presence || tx[:entry_reference].presence
          tx_id.present? && !existing_ids.include?(tx_id)
        end

        if new_transactions.any? || removed_pending
          enable_banking_account.upsert_enable_banking_transactions_snapshot!(existing_transactions + new_transactions)
        end
      end

      { success: true, transactions_count: transactions_count }
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "EnableBankingItem::Importer - Error fetching transactions for account #{enable_banking_account.uid}: #{e.message}"
      { success: false, transactions_count: 0, error: e.message }
    rescue => e
      Rails.logger.error "EnableBankingItem::Importer - Unexpected error fetching transactions for account #{enable_banking_account.uid}: #{e.class} - #{e.message}"
      { success: false, transactions_count: 0, error: e.message }
    end

    # Deduplicate transactions from the Enable Banking API response.
    # Some banks return the same logical transaction multiple times with different
    # entry_reference IDs. We build a composite content key that includes
    # transaction_id (when present) alongside date, amount, currency, creditor,
    # debtor, remittance_information, and status. Per the Enable Banking API docs
    # transaction_id is not guaranteed to be unique, so it cannot be used as
    # the sole dedup criterion. Including it in the composite key preserves
    # legitimately distinct transactions with identical content but different
    # transaction_ids (e.g. two laundromat payments on the same day). (Issue #954)
    def deduplicate_api_transactions(transactions)
      seen = {}
      duplicates_removed = 0

      result = transactions.select do |tx|
        tx = tx.with_indifferent_access
        key = build_transaction_content_key(tx)

        if seen[key]
          duplicates_removed += 1
          false
        else
          seen[key] = true
          true
        end
      end

      if duplicates_removed > 0
        Rails.logger.info(
          "EnableBankingItem::Importer - Removed #{duplicates_removed} content-level " \
          "duplicate(s) from API response (#{transactions.count} → #{result.count} transactions)"
        )
      end

      result
    end

    # Build a composite key for deduplication. Two transactions with different
    # entry_reference values but identical content fields (including
    # transaction_id and credit_debit_indicator) are considered duplicates.
    # transaction_id is included as one component — not a standalone key —
    # because the Enable Banking API docs state it is not guaranteed to be
    # unique. credit_debit_indicator (CRDT/DBIT) is included because
    # transaction_amount.amount is always positive — without it, a payment
    # and a same-day refund of the same amount would produce identical keys.
    # status (BOOK/PDNG) is intentionally excluded: the same logical transaction
    # may appear as PDNG then BOOK across imports and must not create duplicates.
    # Known limitation: when transaction_id is nil for both, pure content
    # comparison applies. This means two genuinely distinct transactions
    # with identical content (same date, amount, direction, creditor, etc.)
    # and no transaction_id would collapse to one. In practice, banks that
    # omit transaction_id rarely produce such exact duplicates in the same
    # API response; timestamps or remittance info usually differ. (Issue #954)
    def build_transaction_content_key(tx)
      date = tx[:booking_date].presence || tx[:value_date]
      amount = tx.dig(:transaction_amount, :amount).presence || tx[:amount]
      currency = tx.dig(:transaction_amount, :currency).presence || tx[:currency]
      creditor = tx.dig(:creditor, :name).presence || tx[:creditor_name]
      debtor = tx.dig(:debtor, :name).presence || tx[:debtor_name]
      remittance = tx[:remittance_information]
      remittance_key = remittance.is_a?(Array) ? remittance.compact.map(&:to_s).sort.join("|") : remittance.to_s
      tid = tx[:transaction_id]
      direction = tx[:credit_debit_indicator]

      [ date, amount, currency, creditor, debtor, remittance_key, tid, direction ].map(&:to_s).join("\x1F")
    end

    class PaginationTruncatedError < StandardError; end

    def fetch_paginated_transactions(enable_banking_account, start_date:, transaction_status:, psu_headers: {})
      all_transactions = []
      continuation_key = nil
      previous_continuation_key = nil
      page_count = 0

      loop do
        page_count += 1

        if page_count > MAX_PAGINATION_PAGES
          msg = "EnableBankingItem::Importer - Pagination limit exceeded for account #{enable_banking_account.uid} (status=#{transaction_status}). Stopped after #{MAX_PAGINATION_PAGES} pages."
          Rails.logger.error(msg)
          raise PaginationTruncatedError, msg
        end

        transactions_data = enable_banking_provider.get_account_transactions(
          account_id: enable_banking_account.api_account_id,
          date_from: start_date,
          continuation_key: continuation_key,
          transaction_status: transaction_status,
          psu_headers: psu_headers
        )

        transactions = transactions_data[:transactions] || []
        all_transactions.concat(transactions)

        previous_continuation_key = continuation_key
        continuation_key = transactions_data[:continuation_key]

        if continuation_key.present? && continuation_key == previous_continuation_key
          msg = "EnableBankingItem::Importer - Repeated continuation_key detected for account #{enable_banking_account.uid} (status=#{transaction_status}). Breaking after #{page_count} pages."
          Rails.logger.error(msg)
          raise PaginationTruncatedError, msg
        end

        break if continuation_key.blank?
      end

      all_transactions
    end

    def filter_transactions_by_date(transactions, start_date)
      return transactions unless start_date

      transactions.reject do |tx|
        tx = tx.with_indifferent_access
        date_str = tx[:booking_date] || tx[:value_date] || tx[:transaction_date]
        next false if date_str.blank?  # Keep if no date (cannot determine)

        begin
          Date.parse(date_str.to_s) < start_date
        rescue ArgumentError
          false  # Keep if date is unparseable
        end
      end
    end

    def tag_as_pending(transactions)
      transactions.map { |tx| tx.merge(_pending: true) }
    end

    def find_enable_banking_account_by_hash(hash_value)
      return nil if hash_value.blank?

      # First: exact uid match (primary identification_hash)
      account = enable_banking_item.enable_banking_accounts.find_by(uid: hash_value.to_s)
      return account if account

      # Second: search in identification_hashes array (PostgreSQL JSONB contains operator)
      enable_banking_item.enable_banking_accounts
        .where("identification_hashes @> ?", [ hash_value.to_s ].to_json)
        .first
    end

    def sync_uids_from_accounts_data(accounts_data)
      return if accounts_data.blank?

      accounts_data.each do |ad|
        next unless ad.is_a?(Hash)
        ad = ad.with_indifferent_access
        identification_hash = ad[:identification_hash]
        current_uid = ad[:uid]
        next if identification_hash.blank? || current_uid.blank?

        eb_acc = find_enable_banking_account_by_hash(identification_hash)
        next unless eb_acc
        # Update the API account_id (UUID) if it has changed (UIDs are session-scoped)
        eb_acc.update!(account_id: current_uid) if eb_acc.account_id != current_uid
      end
    end

    def determine_sync_start_date(enable_banking_account)
      has_stored_transactions = enable_banking_account.raw_transactions_payload.to_a.any?

      # Use user-configured sync_start_date if set, otherwise default
      user_start_date = enable_banking_item.sync_start_date

      if has_stored_transactions
        # For incremental syncs, get transactions from 7 days before last sync
        if enable_banking_item.last_synced_at
          enable_banking_item.last_synced_at.to_date - 7.days
        else
          30.days.ago.to_date
        end
      else
        # Initial sync: use user's configured date or default to 3 months
        user_start_date || 3.months.ago.to_date
      end
    end
end
d
