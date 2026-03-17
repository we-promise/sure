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

      enable_banking_account = enable_banking_item.enable_banking_accounts.find_by(uid: uid.to_s)
      return unless enable_banking_account

      enable_banking_account.upsert_enable_banking_snapshot!(account_data)
      enable_banking_account.save!
    end

    def fetch_and_update_balance(enable_banking_account)
      balance_data = enable_banking_provider.get_account_balances(account_id: enable_banking_account.api_account_id)

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
          enable_banking_account.update!(
            current_balance: amount.to_d,
            currency: currency.presence || enable_banking_account.currency
          )
        end
      end
    rescue Provider::EnableBanking::EnableBankingError => e
      Rails.logger.error "EnableBankingItem::Importer - Error fetching balance for account #{enable_banking_account.uid}: #{e.message}"
    end

    def fetch_and_store_transactions(enable_banking_account)
      start_date = determine_sync_start_date(enable_banking_account)

      all_transactions = []
      continuation_key = nil
      previous_continuation_key = nil
      page_count = 0

      # Paginate through all transactions with safeguards against infinite loops
      loop do
        page_count += 1

        # Safeguard: prevent infinite loops from excessive pagination
        if page_count > MAX_PAGINATION_PAGES
          Rails.logger.error(
            "EnableBankingItem::Importer - Pagination limit exceeded for account #{enable_banking_account.uid}. " \
            "Stopped after #{MAX_PAGINATION_PAGES} pages (#{all_transactions.count} transactions). " \
            "Last continuation_key: #{continuation_key.inspect}"
          )
          break
        end

        transactions_data = enable_banking_provider.get_account_transactions(
          account_id: enable_banking_account.api_account_id,
          date_from: start_date,
          continuation_key: continuation_key
        )

        transactions = transactions_data[:transactions] || []
        all_transactions.concat(transactions)

        previous_continuation_key = continuation_key
        continuation_key = transactions_data[:continuation_key]

        # Safeguard: detect repeated continuation_key (provider returning same key)
        if continuation_key.present? && continuation_key == previous_continuation_key
          Rails.logger.error(
            "EnableBankingItem::Importer - Repeated continuation_key detected for account #{enable_banking_account.uid}. " \
            "Breaking loop after #{page_count} pages (#{all_transactions.count} transactions). " \
            "Repeated key: #{continuation_key.inspect}, last response had #{transactions.count} transactions"
          )
          break
        end

        break if continuation_key.blank?
      end

      transactions_count = all_transactions.count

      if all_transactions.any?
        existing_transactions = enable_banking_account.raw_transactions_payload.to_a
        existing_ids = existing_transactions.map { |tx|
          tx = tx.with_indifferent_access
          tx[:transaction_id].presence || tx[:entry_reference].presence
        }.compact.to_set

        new_transactions = all_transactions.select do |tx|
          # Use transaction_id if present, otherwise fall back to entry_reference
          tx_id = tx[:transaction_id].presence || tx[:entry_reference].presence
          tx_id.present? && !existing_ids.include?(tx_id)
        end

        if new_transactions.any?
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
