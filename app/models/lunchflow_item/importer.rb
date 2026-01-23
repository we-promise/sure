class LunchflowItem::Importer
  include LunchflowTransactionHash

  attr_reader :lunchflow_item, :lunchflow_provider

  def initialize(lunchflow_item, lunchflow_provider:)
    @lunchflow_item = lunchflow_item
    @lunchflow_provider = lunchflow_provider
  end

  def import
    Rails.logger.info "LunchflowItem::Importer - Starting import for item #{lunchflow_item.id}"

    # Step 1: Fetch all accounts from Lunchflow
    accounts_data = fetch_accounts_data
    unless accounts_data
      Rails.logger.error "LunchflowItem::Importer - Failed to fetch accounts data for item #{lunchflow_item.id}"
      return { success: false, error: "Failed to fetch accounts data", accounts_imported: 0, transactions_imported: 0 }
    end

    # Store raw payload
    begin
      lunchflow_item.upsert_lunchflow_snapshot!(accounts_data)
    rescue => e
      Rails.logger.error "LunchflowItem::Importer - Failed to store accounts snapshot: #{e.message}"
      # Continue with import even if snapshot storage fails
    end

    # Step 2: Update linked accounts and create records for new accounts from API
    accounts_updated = 0
    accounts_created = 0
    accounts_failed = 0

    if accounts_data[:accounts].present?
      # Get linked lunchflow account IDs (ones actually imported/used by the user)
      linked_account_ids = lunchflow_item.lunchflow_accounts
                                         .joins(:account_provider)
                                         .pluck(:account_id)
                                         .map(&:to_s)

      # Get all existing lunchflow account IDs (linked or not)
      all_existing_ids = lunchflow_item.lunchflow_accounts.pluck(:account_id).map(&:to_s)

      accounts_data[:accounts].each do |account_data|
        account_id = account_data[:id]&.to_s
        next unless account_id.present?
        next if account_data[:name].blank?

        if linked_account_ids.include?(account_id)
          # Update existing linked accounts
          begin
            import_account(account_data)
            accounts_updated += 1
          rescue => e
            accounts_failed += 1
            Rails.logger.error "LunchflowItem::Importer - Failed to update account #{account_id}: #{e.message}"
          end
        elsif !all_existing_ids.include?(account_id)
          # Create new unlinked lunchflow_account records for accounts we haven't seen before
          # This allows users to link them later via "Setup new accounts"
          begin
            lunchflow_account = lunchflow_item.lunchflow_accounts.build(
              account_id: account_id,
              name: account_data[:name],
              currency: account_data[:currency] || "USD"
            )
            lunchflow_account.upsert_lunchflow_snapshot!(account_data)
            accounts_created += 1
            Rails.logger.info "LunchflowItem::Importer - Created new unlinked account record for #{account_id}"
          rescue => e
            accounts_failed += 1
            Rails.logger.error "LunchflowItem::Importer - Failed to create account #{account_id}: #{e.message}"
          end
        end
      end
    end

    Rails.logger.info "LunchflowItem::Importer - Updated #{accounts_updated} accounts, created #{accounts_created} new (#{accounts_failed} failed)"

    # Step 3: Fetch transactions only for linked accounts with active status
    transactions_imported = 0
    transactions_failed = 0

    lunchflow_item.lunchflow_accounts.joins(:account).merge(Account.visible).each do |lunchflow_account|
      begin
        result = fetch_and_store_transactions(lunchflow_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "LunchflowItem::Importer - Failed to fetch/store transactions for account #{lunchflow_account.account_id}: #{e.message}"
        # Continue with other accounts even if one fails
      end
    end

    Rails.logger.info "LunchflowItem::Importer - Completed import for item #{lunchflow_item.id}: #{accounts_updated} accounts updated, #{accounts_created} new accounts discovered, #{transactions_imported} transactions"

    {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_updated: accounts_updated,
      accounts_created: accounts_created,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed
    }
  end

  private

    def fetch_accounts_data
      begin
        accounts_data = lunchflow_provider.get_accounts
      rescue Provider::Lunchflow::LunchflowError => e
        # Handle authentication errors by marking item as requiring update
        if e.error_type == :unauthorized || e.error_type == :access_forbidden
          begin
            lunchflow_item.update!(status: :requires_update)
          rescue => update_error
            Rails.logger.error "LunchflowItem::Importer - Failed to update item status: #{update_error.message}"
          end
        end
        Rails.logger.error "LunchflowItem::Importer - Lunch flow API error: #{e.message}"
        return nil
      rescue JSON::ParserError => e
        Rails.logger.error "LunchflowItem::Importer - Failed to parse Lunch flow API response: #{e.message}"
        return nil
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error fetching accounts: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        return nil
      end

      # Validate response structure
      unless accounts_data.is_a?(Hash)
        Rails.logger.error "LunchflowItem::Importer - Invalid accounts_data format: expected Hash, got #{accounts_data.class}"
        return nil
      end

      # Handle errors if present in response
      if accounts_data[:error].present?
        handle_error(accounts_data[:error])
        return nil
      end

      accounts_data
    end

    def import_account(account_data)
      # Validate account data structure
      unless account_data.is_a?(Hash)
        Rails.logger.error "LunchflowItem::Importer - Invalid account_data format: expected Hash, got #{account_data.class}"
        raise ArgumentError, "Invalid account data format"
      end

      account_id = account_data[:id]

      # Validate required account_id
      if account_id.blank?
        Rails.logger.warn "LunchflowItem::Importer - Skipping account with missing ID"
        raise ArgumentError, "Account ID is required"
      end

      # Only find existing accounts, don't create new ones during sync
      lunchflow_account = lunchflow_item.lunchflow_accounts.find_by(
        account_id: account_id.to_s
      )

      # Skip if account wasn't previously selected
      unless lunchflow_account
        Rails.logger.debug "LunchflowItem::Importer - Skipping unselected account #{account_id}"
        return
      end

      begin
        lunchflow_account.upsert_lunchflow_snapshot!(account_data)
        lunchflow_account.save!
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowItem::Importer - Failed to save lunchflow_account: #{e.message}"
        raise StandardError.new("Failed to save account: #{e.message}")
      end
    end

    def fetch_and_store_transactions(lunchflow_account)
      start_date = determine_sync_start_date(lunchflow_account)
      include_pending = Rails.configuration.x.lunchflow.include_pending

      Rails.logger.info "LunchflowItem::Importer - Fetching transactions for account #{lunchflow_account.account_id} from #{start_date} (include_pending=#{include_pending})"

      begin
        # Fetch transactions
        transactions_data = lunchflow_provider.get_account_transactions(
          lunchflow_account.account_id,
          start_date: start_date,
          include_pending: include_pending
        )

        # Optional: Debug logging
        if Rails.configuration.x.lunchflow.debug_raw
          Rails.logger.debug "Lunchflow raw response: #{transactions_data.to_json}"
        end

        # Validate response structure
        unless transactions_data.is_a?(Hash)
          Rails.logger.error "LunchflowItem::Importer - Invalid transactions_data format for account #{lunchflow_account.account_id}"
          return { success: false, transactions_count: 0, error: "Invalid response format" }
        end

        transactions_count = transactions_data[:transactions]&.count || 0
        Rails.logger.info "LunchflowItem::Importer - Fetched #{transactions_count} transactions for account #{lunchflow_account.account_id}"

        # Store transactions in the account
        if transactions_data[:transactions].present?
          begin
            existing_transactions = lunchflow_account.raw_transactions_payload.to_a

            # Build set of existing transaction IDs for efficient lookup
            # For transactions with IDs: use the ID directly
            # For transactions without IDs (blank/nil): use content hash to prevent duplicate storage
            existing_ids = existing_transactions.map do |tx|
              tx_with_access = tx.with_indifferent_access
              tx_id = tx_with_access[:id]

              if tx_id.blank?
                # Generate content hash for blank-ID transactions to detect duplicates
                content_hash_for_transaction(tx_with_access)
              else
                tx_id
              end
            end.compact.to_set

            # Filter to ONLY truly new transactions (skip duplicates)
            # For transactions WITH IDs: skip if ID already exists (true duplicates)
            # For transactions WITHOUT IDs: skip if content hash exists (prevents unbounded growth)
            # Note: Pending transactions may update from pending→posted, but we treat them as immutable snapshots
            new_transactions = transactions_data[:transactions].select do |tx|
              next false unless tx.is_a?(Hash)

              tx_with_access = tx.with_indifferent_access
              tx_id = tx_with_access[:id]

              if tx_id.blank?
                # Use content hash to detect if we've already stored this exact transaction
                content_hash = content_hash_for_transaction(tx_with_access)
                !existing_ids.include?(content_hash)
              else
                # If has ID, only include if not already stored
                !existing_ids.include?(tx_id)
              end
            end

            if new_transactions.any?
              Rails.logger.info "LunchflowItem::Importer - Storing #{new_transactions.count} new transactions (#{existing_transactions.count} existing, #{transactions_data[:transactions].count - new_transactions.count} duplicates skipped) for account #{lunchflow_account.account_id}"
              lunchflow_account.upsert_lunchflow_transactions_snapshot!(existing_transactions + new_transactions)
            else
              Rails.logger.info "LunchflowItem::Importer - No new transactions to store (all #{transactions_data[:transactions].count} were duplicates) for account #{lunchflow_account.account_id}"
            end
          rescue => e
            Rails.logger.error "LunchflowItem::Importer - Failed to store transactions for account #{lunchflow_account.account_id}: #{e.message}"
            return { success: false, transactions_count: 0, error: "Failed to store transactions: #{e.message}" }
          end
        else
          Rails.logger.info "LunchflowItem::Importer - No transactions to store for account #{lunchflow_account.account_id}"
        end

        # Fetch and update balance
        begin
          fetch_and_update_balance(lunchflow_account)
        rescue => e
          # Log but don't fail transaction import if balance fetch fails
          Rails.logger.warn "LunchflowItem::Importer - Failed to update balance for account #{lunchflow_account.account_id}: #{e.message}"
        end

        # Fetch holdings for investment/crypto accounts
        begin
          fetch_and_store_holdings(lunchflow_account)
        rescue => e
          # Log but don't fail sync if holdings fetch fails
          Rails.logger.warn "LunchflowItem::Importer - Failed to fetch holdings for account #{lunchflow_account.account_id}: #{e.message}"
        end

        { success: true, transactions_count: transactions_count }
      rescue Provider::Lunchflow::LunchflowError => e
        Rails.logger.error "LunchflowItem::Importer - Lunchflow API error for account #{lunchflow_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: e.message }
      rescue JSON::ParserError => e
        Rails.logger.error "LunchflowItem::Importer - Failed to parse transaction response for account #{lunchflow_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: "Failed to parse response" }
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error fetching transactions for account #{lunchflow_account.id}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, transactions_count: 0, error: "Unexpected error: #{e.message}" }
      end
    end

    def fetch_and_update_balance(lunchflow_account)
      begin
        balance_data = lunchflow_provider.get_account_balance(lunchflow_account.account_id)

        # Validate response structure
        unless balance_data.is_a?(Hash)
          Rails.logger.error "LunchflowItem::Importer - Invalid balance_data format for account #{lunchflow_account.account_id}"
          return
        end

        if balance_data[:balance].present?
          balance_info = balance_data[:balance]

          # Validate balance info structure
          unless balance_info.is_a?(Hash)
            Rails.logger.error "LunchflowItem::Importer - Invalid balance info format for account #{lunchflow_account.account_id}"
            return
          end

          # Only update if we have a valid amount
          if balance_info[:amount].present?
            lunchflow_account.update!(
              current_balance: balance_info[:amount],
              currency: balance_info[:currency].presence || lunchflow_account.currency
            )
          else
            Rails.logger.warn "LunchflowItem::Importer - No amount in balance data for account #{lunchflow_account.account_id}"
          end
        else
          Rails.logger.warn "LunchflowItem::Importer - No balance data returned for account #{lunchflow_account.account_id}"
        end
      rescue Provider::Lunchflow::LunchflowError => e
        Rails.logger.error "LunchflowItem::Importer - Lunchflow API error fetching balance for account #{lunchflow_account.id}: #{e.message}"
        # Don't fail if balance fetch fails
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowItem::Importer - Failed to save balance for account #{lunchflow_account.id}: #{e.message}"
        # Don't fail if balance save fails
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error updating balance for account #{lunchflow_account.id}: #{e.class} - #{e.message}"
        # Don't fail if balance update fails
      end
    end

    def fetch_and_store_holdings(lunchflow_account)
      # Only fetch holdings for investment/crypto accounts
      account = lunchflow_account.current_account
      return unless account.present?
      return unless [ "Investment", "Crypto" ].include?(account.accountable_type)

      # Skip if holdings are not supported for this account
      unless lunchflow_account.holdings_supported?
        Rails.logger.debug "LunchflowItem::Importer - Skipping holdings fetch for account #{lunchflow_account.account_id} (holdings not supported)"
        return
      end

      Rails.logger.info "LunchflowItem::Importer - Fetching holdings for account #{lunchflow_account.account_id}"

      begin
        holdings_data = lunchflow_provider.get_account_holdings(lunchflow_account.account_id)

        # Validate response structure
        unless holdings_data.is_a?(Hash)
          Rails.logger.error "LunchflowItem::Importer - Invalid holdings_data format for account #{lunchflow_account.account_id}"
          return
        end

        # Check if holdings are not supported (501 response)
        if holdings_data[:holdings_not_supported]
          Rails.logger.info "LunchflowItem::Importer - Holdings not supported for account #{lunchflow_account.account_id}, disabling future requests"
          lunchflow_account.update!(holdings_supported: false)
          return
        end

        # Store holdings payload for processing
        holdings_array = holdings_data[:holdings] || []
        Rails.logger.info "LunchflowItem::Importer - Fetched #{holdings_array.count} holdings for account #{lunchflow_account.account_id}"

        lunchflow_account.update!(raw_holdings_payload: holdings_array)
      rescue Provider::Lunchflow::LunchflowError => e
        Rails.logger.error "LunchflowItem::Importer - Lunchflow API error fetching holdings for account #{lunchflow_account.id}: #{e.message}"
        # Don't fail if holdings fetch fails
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "LunchflowItem::Importer - Failed to save holdings for account #{lunchflow_account.id}: #{e.message}"
        # Don't fail if holdings save fails
      rescue => e
        Rails.logger.error "LunchflowItem::Importer - Unexpected error fetching holdings for account #{lunchflow_account.id}: #{e.class} - #{e.message}"
        # Don't fail if holdings fetch fails
      end
    end

    def determine_sync_start_date(lunchflow_account)
      # Check if this account has any stored transactions
      # If not, treat it as a first sync for this account even if the item has been synced before
      has_stored_transactions = lunchflow_account.raw_transactions_payload.to_a.any?

      if has_stored_transactions
        # Account has been synced before, use item-level logic with buffer
        # For subsequent syncs, fetch from last sync date with a buffer
        if lunchflow_item.last_synced_at
          lunchflow_item.last_synced_at - 7.days
        else
          # Fallback if item hasn't been synced but account has transactions
          90.days.ago
        end
      else
        # Account has no stored transactions - this is a first sync for this account
        # Use account creation date or a generous historical window
        account_baseline = lunchflow_account.created_at || Time.current
        first_sync_window = [ account_baseline - 7.days, 90.days.ago ].max

        # Use the more recent of: (account created - 7 days) or (90 days ago)
        # This caps old accounts at 90 days while respecting recent account creation dates
        first_sync_window
      end
    end

    def handle_error(error_message)
      # Mark item as requiring update for authentication-related errors
      error_msg_lower = error_message.to_s.downcase
      needs_update = error_msg_lower.include?("authentication") ||
                     error_msg_lower.include?("unauthorized") ||
                     error_msg_lower.include?("api key")

      if needs_update
        begin
          lunchflow_item.update!(status: :requires_update)
        rescue => e
          Rails.logger.error "LunchflowItem::Importer - Failed to update item status: #{e.message}"
        end
      end

      Rails.logger.error "LunchflowItem::Importer - API error: #{error_message}"
      raise Provider::Lunchflow::LunchflowError.new(
        "Lunchflow API error: #{error_message}",
        :api_error
      )
    end
end
