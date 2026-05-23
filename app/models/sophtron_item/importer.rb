require "set"

# Imports account and transaction data from Sophtron API.
#
# This class orchestrates the complete import process for a SophtronItem:
# 1. Fetches all accounts from Sophtron
# 2. Updates existing linked accounts with latest data
# 3. Creates SophtronAccount records for newly discovered accounts
# 4. Fetches and stores transactions for all linked accounts
# 5. Updates account balances
#
# The importer maintains a separation between "discovered" accounts (any account
# returned by the Sophtron API) and "linked" accounts (accounts the user has
# explicitly connected to Maybe Accounts). This allows users to selectively
# import accounts of their choosing.
class SophtronItem::Importer
  INCREMENTAL_SYNC_BUFFER_DAYS = 60

  attr_reader :sophtron_item, :sophtron_provider, :sync

  # Initializes a new importer.
  #
  # @param sophtron_item [SophtronItem] The Sophtron item to import data for
  # @param sophtron_provider [Provider::Sophtron] Configured Sophtron API client
  # @param sync [Sync, nil] Optional sync record whose window should guide import scope
  def initialize(sophtron_item, sophtron_provider:, sync: nil)
    @sophtron_item = sophtron_item
    @sophtron_provider = sophtron_provider
    @sync = sync
  end

  # Performs the complete import process for this Sophtron item.
  #
  # This method:
  # - Fetches all accounts from Sophtron API
  # - Stores raw account data snapshot
  # - Updates existing linked accounts
  # - Creates records for newly discovered accounts
  # - Fetches transactions for all linked accounts
  # - Updates account balances
  #
  # @return [Hash] Import results with the following keys:
  #   - :success [Boolean] Overall success status
  #   - :accounts_updated [Integer] Number of existing accounts updated
  #   - :accounts_created [Integer] Number of new account records created
  #   - :accounts_failed [Integer] Number of accounts that failed to import
  #   - :transactions_imported [Integer] Total number of transactions imported
  #   - :transactions_failed [Integer] Number of accounts with transaction import failures
  # @example
  #   result = importer.import
  #   # => { success: true, accounts_updated: 2, accounts_created: 1,
  #   #      accounts_failed: 0, transactions_imported: 150, transactions_failed: 0 }
  def import
    Rails.logger.info "SophtronItem::Importer - Starting import for item #{sophtron_item.id}"
    unless sophtron_item.user_institution_id.present?
      error_message = "Sophtron institution connection is incomplete"
      Rails.logger.warn "SophtronItem::Importer - Item #{sophtron_item.id} has no Sophtron UserInstitutionID"
      sophtron_item.update!(
        status: :requires_update,
        last_connection_error: error_message
      )

      return {
        success: false,
        error: error_message,
        accounts_updated: 0,
        accounts_created: 0,
        accounts_failed: 0,
        transactions_imported: 0,
        transactions_failed: 0
      }
    end

    # Step 1: Fetch all accounts from Sophtron
    accounts_data = fetch_accounts_data
    unless accounts_data
      Rails.logger.error "SophtronItem::Importer - Failed to fetch accounts data for item #{sophtron_item.id}"
      return { success: false, error: "Failed to fetch accounts data", accounts_imported: 0, transactions_imported: 0 }
    end

    # Store raw payload
    begin
      sophtron_item.upsert_sophtron_snapshot!(accounts_data)
    rescue => e
      Rails.logger.error "SophtronItem::Importer - Failed to store accounts snapshot: #{e.message}"
      # Continue with import even if snapshot storage fails
    end

    # Step 2: Update linked accounts and create records for new accounts from API
    accounts_updated = 0
    accounts_created = 0
    accounts_failed = 0

    if accounts_data[:accounts].present?
      # Get linked sophtron account IDs (ones actually imported/used by the user)
      linked_account_ids = sophtron_item.sophtron_accounts
                                         .joins(:account_provider)
                                         .pluck(:account_id)
                                         .map(&:to_s)
      # Get all existing sophtron account IDs (linked or not)
      all_existing_ids = sophtron_item.sophtron_accounts.pluck(:account_id).map(&:to_s)
      accounts_data[:accounts].each do |account_data|
        account_id = (account_data[:account_id] || account_data[:id])&.to_s
        next unless account_id.present?
        account_name = account_data[:account_name] || account_data[:name]
        next if account_name.blank?
        if linked_account_ids.include?(account_id)
          # Update existing linked accounts
          begin
            import_account(account_data)
            accounts_updated += 1
          rescue => e
            accounts_failed += 1
            Rails.logger.error "SophtronItem::Importer - Failed to update account #{account_id}: #{e.message}"
          end
        elsif !all_existing_ids.include?(account_id)
          # Create new unlinked sophtron_account records for accounts we haven't seen before
          # This allows users to link them later via "Setup new accounts"
          begin
            sophtron_account = sophtron_item.sophtron_accounts.build(
              account_id: account_id,
              name: account_name,
              currency: account_data[:currency] || "USD"
            )
            sophtron_account.upsert_sophtron_snapshot!(account_data)
            accounts_created += 1
            Rails.logger.info "SophtronItem::Importer - Created new unlinked account record for #{account_id}"
          rescue => e
            accounts_failed += 1
            Rails.logger.error "SophtronItem::Importer - Failed to create account #{account_id}: #{e.message}"
          end
        end
      end
    end

    Rails.logger.info "SophtronItem::Importer - Updated #{accounts_updated} accounts, created #{accounts_created} new (#{accounts_failed} failed)"

    # Step 3: Fetch transactions only for linked accounts with active status
    transactions_imported = 0
    transactions_failed = 0

    linked_accounts = sophtron_item.automatic_sync_sophtron_accounts
    linked_accounts.each do |sophtron_account|
      begin
        result = fetch_and_store_transactions(sophtron_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
          break if result[:requires_update]
        end
      rescue => e
        transactions_failed += 1
        Rails.logger.error "SophtronItem::Importer - Failed to fetch/store transactions for account #{sophtron_account.account_id}: #{e.message}"
        # Continue with other accounts even if one fails
      end
    end

    Rails.logger.info "SophtronItem::Importer - Completed import for item #{sophtron_item.id}: #{accounts_updated} accounts updated, #{accounts_created} new accounts discovered, #{transactions_imported} transactions"

    {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_updated: accounts_updated,
      accounts_created: accounts_created,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed
    }
  end

  def import_transactions_after_refresh(sophtron_account)
    fetch_and_store_transactions(sophtron_account, refresh: false)
  end

  private

    def fetch_accounts_data
      begin
        accounts_data = Provider::Sophtron.response_data!(sophtron_provider.get_accounts(sophtron_item.user_institution_id))
      rescue Provider::Sophtron::Error => e
        # Handle authentication errors by marking item as requiring update
        if e.error_type == :unauthorized || e.error_type == :access_forbidden
          begin
            sophtron_item.update!(status: :requires_update)
          rescue => update_error
            Rails.logger.error "SophtronItem::Importer - Failed to update item status: #{update_error.message}"
          end
        end
        Rails.logger.error "SophtronItem::Importer - Sophtron API error: #{e.message}"
        return nil
      rescue JSON::ParserError => e
        Rails.logger.error "SophtronItem::Importer - Failed to parse Sophtron API response: #{e.message}"
        return nil
      rescue => e
        Rails.logger.error "SophtronItem::Importer - Unexpected error fetching accounts: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        return nil
      end

      # Validate response structure
      unless accounts_data.is_a?(Hash)
        Rails.logger.error "SophtronItem::Importer - Invalid accounts_data format: expected Hash, got #{accounts_data.class}"
        return nil
      end

      # Handle errors if present in response
      if accounts_data[:error].present?
        handle_error(accounts_data[:error])
        return nil
      end

      accounts_data
    end

    # Imports and updates a single account from Sophtron data.
    #
    # This method only updates existing SophtronAccount records that were
    # previously created. It does not create new accounts during sync.
    #
    # @param account_data [Hash] Raw account data from Sophtron API
    # @return [void]
    # @raise [ArgumentError] if account_data is invalid or account_id is missing
    # @raise [StandardError] if the account cannot be saved
    def import_account(account_data)
      # Validate account data structure
      unless account_data.is_a?(Hash)
        Rails.logger.error "SophtronItem::Importer - Invalid account_data format: expected Hash, got #{account_data.class}"
        raise ArgumentError, "Invalid account data format"
      end

      account_id = (account_data[:account_id] || account_data[:id])&.to_s

      # Validate required account_id
      if account_id.blank?
        Rails.logger.warn "SophtronItem::Importer - Skipping account with missing ID"
        raise ArgumentError, "Account ID is required"
      end

      # Only find existing accounts, don't create new ones during sync
      sophtron_account = sophtron_item.sophtron_accounts.find_by(
        account_id: account_id
      )

      # Skip if account wasn't previously selected
      unless sophtron_account
        return
      end

      begin
        sophtron_account.upsert_sophtron_snapshot!(account_data)
        sophtron_account.save!
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "SophtronItem::Importer - Failed to save sophtron_account: #{e.message}"
        raise StandardError.new("Failed to save account: #{e.message}")
      end
    end

    # Fetches and stores transactions for a Sophtron account.
    #
    # This method:
    # 1. Determines the appropriate sync start date
    # 2. Fetches transactions from the Sophtron API
    # 3. Deduplicates against existing transactions
    # 4. Stores new transactions in raw_transactions_payload
    # 5. Updates the account balance
    #
    # @param sophtron_account [SophtronAccount] The account to fetch transactions for
    # @return [Hash] Result with keys:
    #   - :success [Boolean] Whether the fetch was successful
    #   - :transactions_count [Integer] Number of transactions fetched
    #   - :error [String, nil] Error message if failed
    def fetch_and_store_transactions(sophtron_account, refresh: true)
      start_date = determine_sync_start_date(sophtron_account)
      Rails.logger.info "SophtronItem::Importer - Fetching transactions for account #{sophtron_account.account_id} from #{start_date}"

      begin
        if refresh && !initial_transaction_fetch?(sophtron_account)
          refresh_result = refresh_account_before_transaction_fetch(sophtron_account)
          return refresh_result if refresh_result.present?
        end

        # Fetch transactions
        transactions_data = Provider::Sophtron.response_data!(
          sophtron_provider.get_account_transactions(
            sophtron_account.account_id,
            start_date: start_date
          )
        )

        # Validate response structure
        unless transactions_data.is_a?(Hash)
          Rails.logger.error "SophtronItem::Importer - Invalid transactions_data format for account #{sophtron_account.account_id}"
          return { success: false, transactions_count: 0, error: "Invalid response format" }
        end

        transactions = transactions_data[:transactions]
        unless transactions.is_a?(Array)
          Rails.logger.error "SophtronItem::Importer - Missing transactions array for account #{sophtron_account.account_id}"
          return { success: false, transactions_count: 0, error: "Missing transactions array" }
        end

        transactions_count = transactions.count
        Rails.logger.info "SophtronItem::Importer - Fetched #{transactions_count} transactions for account #{sophtron_account.account_id}"

        # Store transactions in the account
        if transactions.any?
          begin
            existing_transactions = sophtron_account.raw_transactions_payload.to_a

            # Build set of existing transaction IDs for efficient lookup
            existing_ids = existing_transactions.map do |tx|
              tx.with_indifferent_access[:id]
            end.to_set

            # Filter to ONLY truly new transactions (skip duplicates)
            # Transactions are immutable on the bank side, so we don't need to update them
            new_transactions = transactions.select do |tx|
              next false unless tx.is_a?(Hash)

              tx_id = tx.with_indifferent_access[:id]
              tx_id.present? && !existing_ids.include?(tx_id)
            end

            if new_transactions.any?
              Rails.logger.info "SophtronItem::Importer - Storing #{new_transactions.count} new transactions (#{existing_transactions.count} existing, #{transactions.count - new_transactions.count} duplicates skipped) for account #{sophtron_account.account_id}"
              sophtron_account.upsert_sophtron_transactions_snapshot!(existing_transactions + new_transactions)
            else
              Rails.logger.info "SophtronItem::Importer - No new transactions to store (all #{transactions.count} were duplicates) for account #{sophtron_account.account_id}"
              sophtron_account.upsert_sophtron_transactions_snapshot!(existing_transactions) if sophtron_account.raw_transactions_payload.nil?
            end
          rescue => e
            Rails.logger.error "SophtronItem::Importer - Failed to store transactions for account #{sophtron_account.account_id}: #{e.message}"
            return { success: false, transactions_count: 0, error: "Failed to store transactions: #{e.message}" }
          end
        else
          Rails.logger.info "SophtronItem::Importer - No transactions to store for account #{sophtron_account.account_id}"
          sophtron_account.upsert_sophtron_transactions_snapshot!([]) if sophtron_account.raw_transactions_payload.nil?
        end

        { success: true, transactions_count: transactions_count }
      rescue Provider::Sophtron::Error => e
        requires_update = e.error_type.in?([ :unauthorized, :access_forbidden ])
        sophtron_item.update!(status: :requires_update) if requires_update
        Rails.logger.error "SophtronItem::Importer - Sophtron API error for account #{sophtron_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: e.message, requires_update: requires_update }
      rescue JSON::ParserError => e
        Rails.logger.error "SophtronItem::Importer - Failed to parse transaction response for account #{sophtron_account.id}: #{e.message}"
        { success: false, transactions_count: 0, error: "Failed to parse response" }
      rescue => e
        Rails.logger.error "SophtronItem::Importer - Unexpected error fetching transactions for account #{sophtron_account.id}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, transactions_count: 0, error: "Unexpected error: #{e.message}" }
      end
    end

    def refresh_account_before_transaction_fetch(sophtron_account)
      refresh_response = Provider::Sophtron.response_data!(sophtron_provider.refresh_account(sophtron_account.account_id))
      job_id = refresh_response.with_indifferent_access[:JobID] || refresh_response.with_indifferent_access[:job_id]
      return nil if job_id.blank?

      job = Provider::Sophtron.response_data!(sophtron_provider.get_job_information(job_id))
      sophtron_item.upsert_job_snapshot!(job)

      if Provider::Sophtron.job_requires_input?(job)
        sophtron_item.update!(
          status: :requires_update,
          current_job_id: job_id,
          last_connection_error: "Sophtron refresh requires MFA"
        )
        return { success: false, transactions_count: 0, error: "Sophtron refresh requires MFA", requires_update: true }
      end

      if Provider::Sophtron.job_failed?(job)
        return { success: false, transactions_count: 0, error: "Sophtron refresh failed" }
      end

      unless Provider::Sophtron.job_success?(job) || Provider::Sophtron.job_completed?(job)
        SophtronRefreshPollJob.set(wait: SophtronRefreshPollJob::POLL_INTERVAL).perform_later(
          sophtron_account,
          job_id: job_id,
          sync: sync
        )

        return { success: true, transactions_count: 0, refresh_pending: true }
      end

      nil
    rescue Provider::Sophtron::Error => e
      requires_update = e.error_type.in?([ :unauthorized, :access_forbidden ])
      sophtron_item.update!(status: :requires_update) if requires_update
      Rails.logger.error "SophtronItem::Importer - Sophtron API error refreshing account #{sophtron_account.id}: #{e.message}"
      { success: false, transactions_count: 0, error: e.message, requires_update: requires_update }
    end

    # Determines the appropriate start date for fetching transactions.
    #
    # Logic:
    # - For accounts with stored transactions: uses last sync date minus a buffer
    # - For new accounts: uses the sync window or provider default initial lookback
    #
    # This captures late-arriving transactions while keeping history bounded.
    #
    # @param sophtron_account [SophtronAccount] The account to determine start date for
    # @return [Date] The start date for transaction sync
    def determine_sync_start_date(sophtron_account)
      configured_start = sync&.window_start_date || sophtron_item.sync_start_date&.to_date
      max_history_start = SophtronItem::MAX_TRANSACTION_HISTORY_YEARS.years.ago.to_date
      floor_start = configured_start ? [ configured_start, max_history_start ].max : nil

      if !initial_transaction_fetch?(sophtron_account)
        # Account has been synced before, use item-level logic with buffer
        # For subsequent syncs, fetch from last sync date with a buffer
        if sophtron_item.last_synced_at
          [ sophtron_item.last_synced_at.to_date - INCREMENTAL_SYNC_BUFFER_DAYS, floor_start ].compact.max
        else
          # Fallback if item hasn't been synced but account has transactions
          floor_start || sophtron_item.initial_load_window_start_date
        end
      else
        # Account has no stored transactions - this is a first sync for this account
        # Use the configured sync window if present, otherwise the provider's default initial lookback.
        floor_start || sophtron_item.initial_load_window_start_date
      end
    end

    def initial_transaction_fetch?(sophtron_account)
      sophtron_account.raw_transactions_payload.nil? && sophtron_item.last_synced_at.blank?
    end

    # Handles API errors and marks the item for re-authentication if needed.
    #
    # Authentication-related errors cause the item status to be set to
    # :requires_update, prompting the user to re-enter credentials.
    #
    # @param error_message [String] The error message from the API
    # @return [void]
    # @raise [Provider::Sophtron::Error] Always raises an error with the message
    def handle_error(error_message)
      # Mark item as requiring update for authentication-related errors
      error_msg_lower = error_message.to_s.downcase
      needs_update = error_msg_lower.include?("authentication") ||
                     error_msg_lower.include?("unauthorized") ||
                     error_msg_lower.include?("user id") ||
                     error_msg_lower.include?("access key")

      if needs_update
        begin
          sophtron_item.update!(status: :requires_update)
        rescue => e
          Rails.logger.error "SophtronItem::Importer - Failed to update item status: #{e.message}"
        end
      end

      Rails.logger.error "SophtronItem::Importer - API error: #{error_message}"
      raise Provider::Sophtron::Error.new(
        "Sophtron API error: #{error_message}",
        :api_error
      )
    end
end
