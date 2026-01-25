class MercuryItem::Importer
  attr_reader :mercury_item, :mercury_provider

  def initialize(mercury_item, mercury_provider:)
    @mercury_item = mercury_item
    @mercury_provider = mercury_provider
  end

  def import
    Rails.logger.info "MercuryItem::Importer - Starting import for item #{mercury_item.id}"

    # Step 1: Fetch all accounts from Mercury
    accounts_data = fetch_accounts_data
    unless accounts_data
      Rails.logger.error "MercuryItem::Importer - Failed to fetch accounts data for item #{mercury_item.id}"
      return { success: false, error: "Failed to fetch accounts data", accounts_imported: 0, transactions_imported: 0 }
    end

    # Store raw payload
    begin
      mercury_item.upsert_mercury_snapshot!(accounts_data)
    rescue => e
      Rails.logger.error "MercuryItem::Importer - Failed to store accounts snapshot: #{e.message}"
      # Continue with import even if snapshot storage fails
    end

    # Step 2: Update linked accounts and create records for new accounts from API
    accounts_updated = 0
    accounts_created = 0
    accounts_failed = 0

    if accounts_data[:accounts].present?
      # Get linked mercury account IDs (ones actually imported/used by the user)
      linked_account_ids = mercury_item.mercury_accounts
                                       .joins(:account_provider)
                                       .pluck(:account_id)
                                       .map(&:to_s)

      # Get all existing mercury account IDs (linked or not)
      all_existing_ids = mercury_item.mercury_accounts.pluck(:account_id).map(&:to_s)

      accounts_data[:accounts].each do |account_data|
        account_id = account_data[:id]&.to_s
        next unless account_id.present?

        # Mercury uses 'name' or 'nickname' for account name
        account_name = account_data[:nickname].presence || account_data[:name].presence || account_data[:legalBusinessName].presence
        next if account_name.blank?

        if linked_account_ids.include?(account_id)
          # Update existing linked accounts
          begin
            import_account(account_data)
            accounts_updated += 1
          rescue => e
            accounts_failed += 1
            Rails.logger.error "MercuryItem::Importer - Failed to update account #{account_id}: #{e.message}"
          end
        elsif !all_existing_ids.include?(account_id)
          # Create new unlinked mercury_account records for accounts we haven't seen before
          # This allows users to link them later via "Setup new accounts"
          begin
            mercury_account = mercury_item.mercury_accounts.build(
              account_id: account_id,
              name: account_name,
              currency: "USD"  # Mercury is US-only, always USD
            )
            mercury_account.upsert_mercury_snapshot!(account_data)
            accounts_created += 1
            Rails.logger.info "MercuryItem::Importer - Created new unlinked account record for #{account_id}"
          rescue => e
            accounts_failed += 1
            Rails.logger.error "MercuryItem::Importer - Failed to create account #{account_id}: #{e.message}"
          end
        end
      end
    end

    Rails.logger.info "MercuryItem::Importer - Updated #{accounts_updated} accounts, created #{accounts_created} new (#{accounts_failed} failed)"

    # Step 3: Fetch transactions only for linked accounts with active status
    transactions_imported = 0
    transactions_failed = 0

    mercury_item.mercury_accounts.joins(:account).merge(Account.visible).each do |mercury_account|
      begin
        result = fetch_and_store_transactions(mercury_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "MercuryItem::Importer - Failed to fetch/store transactions for account #{mercury_account.account_id}: #{e.message}"
        # Continue with other accounts even if one fails
      end
    end

    Rails.logger.info "MercuryItem::Importer - Completed import for item #{mercury_item.id}: #{accounts_updated} accounts updated, #{accounts_created} new accounts discovered, #{transactions_imported} transactions"

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
        accounts_data = mercury_provider.get_accounts
      rescue Provider::Mercury::MercuryError => e
        # Handle authentication errors by marking item as requiring update
        if e.error_type == :unauthorized || e.error_type == :access_forbidden
          begin
            mercury_item.update!(status: :requires_update)
          rescue => update_error
            Rails.logger.error "MercuryItem::Importer - Failed to update item status: #{update_error.message}"
          end
        end
        Rails.logger.error "MercuryItem::Importer - Mercury API error: #{e.message}"
        return nil
      rescue JSON::ParserError => e
        Rails.logger.error "MercuryItem::Importer - Failed to parse Mercury API response: #{e.message}"
        return nil
      rescue => e
        Rails.logger.error "MercuryItem::Importer - Unexpected error fetching accounts: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        return nil
      end

      # Validate response structure
      unless accounts_data.is_a?(Hash)
        Rails.logger.error "MercuryItem::Importer - Invalid accounts_data format: expected Hash, got #{accounts_data.class}"
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
        Rails.logger.error "MercuryItem::Importer - Invalid account_data format: expected Hash, got #{account_data.class}"
        raise ArgumentError, "Invalid account data format"
      end

      account_id = account_data[:id]

      # Validate required account_id
      if account_id.blank?
        Rails.logger.warn "MercuryItem::Importer - Skipping account with missing ID"
        raise ArgumentError, "Account ID is required"
      end

      # Only find existing accounts, don't create new ones during sync
      mercury_account = mercury_item.mercury_accounts.find_by(
        account_id: account_id.to_s
      )

      # Skip if account wasn't previously selected
      unless mercury_account
        Rails.logger.debug "MercuryItem::Importer - Skipping unselected account #{account_id}"
        return
      end

      begin
        mercury_account.upsert_mercury_snapshot!(account_data)
        mercury_account.save!
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "MercuryItem::Importer - Failed to save mercury_account: #{e.message}"
        raise StandardError.new("Failed to save account: #{e.message}")
      end
    end

    def fetch_and_store_transactions(mercury_account)
      start_date = determine_sync_start_date(mercury_account)
      Rails.logger.info "MercuryItem::Importer - Fetching transactions for account #{mercury_account.account_id} from #{start_date}"

      begin
        # Fetch transactions
        transactions_data = mercury_provider.get_account_transactions(
          mercury_account.account_id,
          start_date: start_date
        )

        # Validate response structure
        unless transactions_data.is_a?(Hash)
          Rails.logger.error "MercuryItem::Importer - Invalid transactions_data format for account #{mercury_account.account_id}"
          return { success: false, transactions_count: 0, error: "Invalid response format" }
        end

        transactions_count = transactions_data[:transactions]&.count || 0
        Rails.logger.info "MercuryItem::Importer - Fetched #{transactions_count} transactions for account #{mercury_account.account_id}"

        # Store transactions in the account
        if transactions_data[:transactions].present?
          begin
            existing_transactions = mercury_account.raw_transactions_payload.to_a

            # Build set of existing transaction IDs for efficient lookup
            existing_ids = existing_transactions.map do |tx|
              tx.with_indifferent_access[:id]
            end.to_set

            # Filter to ONLY truly new transactions (skip duplicates)
            # Transactions are immutable on the bank side, so we don't need to update them
            new_transactions = transactions_data[:transactions].select do |tx|
              next false unless tx.is_a?(Hash)

              tx_id = tx.with_indifferent_access[:id]
              tx_id.present? && !existing_ids.include?(tx_id)
            end

            if new_transactions.any?
              Rails.logger.info "MercuryItem::Importer - Storing #{new_transactions.count} new transactions (#{existing_transactions.count} existing, #{transactions_data[:transactions].count - new_transactions.count} duplicates skipped) for account #{mercury_account.account_id}"
              mercury_account.upsert_mercury_transactions_snapshot!(existing_transactions + new_transactions)
            else
              Rails.logger.info "MercuryItem::Importer - No new transactions to store (all #{transactions_data[:transactions].count} were duplicates) for account #{mercury_account.account_id}"
            end
          rescue => e
            Rails.logger.error "MercuryItem::Importer - Failed to store transactions for account #{mercury_account.account_id}: #{e.message}"
            return { success: false, transactions_count: 0, error: "Failed to store transactions: #{e.message}" }
          end
        else
          Rails.logger.info "MercuryItem::Importer - No transactions to store for account #{mercury_account.account_id}"
        end

        { success: true, transactions_count: transactions_count }
      rescue Provider::Mercury::MercuryError => e
        Rails.logger.error "MercuryItem::Importer - Mercury API error for account #{mercury_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: e.message }
      rescue JSON::ParserError => e
        Rails.logger.error "MercuryItem::Importer - Failed to parse transaction response for account #{mercury_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: "Failed to parse response" }
      rescue => e
        Rails.logger.error "MercuryItem::Importer - Unexpected error fetching transactions for account #{mercury_account.id}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, transactions_count: 0, error: "Unexpected error: #{e.message}" }
      end
    end

    def determine_sync_start_date(mercury_account)
      # Check if this account has any stored transactions
      # If not, treat it as a first sync for this account even if the item has been synced before
      has_stored_transactions = mercury_account.raw_transactions_payload.to_a.any?

      if has_stored_transactions
        # Account has been synced before, use item-level logic with buffer
        # For subsequent syncs, fetch from last sync date with a buffer
        if mercury_item.last_synced_at
          mercury_item.last_synced_at - 7.days
        else
          # Fallback if item hasn't been synced but account has transactions
          90.days.ago
        end
      else
        # Account has no stored transactions - this is a first sync for this account
        # Use account creation date or a generous historical window
        account_baseline = mercury_account.created_at || Time.current
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
                     error_msg_lower.include?("api key") ||
                     error_msg_lower.include?("api token")

      if needs_update
        begin
          mercury_item.update!(status: :requires_update)
        rescue => e
          Rails.logger.error "MercuryItem::Importer - Failed to update item status: #{e.message}"
        end
      end

      Rails.logger.error "MercuryItem::Importer - API error: #{error_message}"
      raise Provider::Mercury::MercuryError.new(
        "Mercury API error: #{error_message}",
        :api_error
      )
    end
end
