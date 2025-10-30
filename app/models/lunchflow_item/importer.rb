class LunchflowItem::Importer
  attr_reader :lunchflow_item, :lunchflow_provider

  def initialize(lunchflow_item, lunchflow_provider:)
    @lunchflow_item = lunchflow_item
    @lunchflow_provider = lunchflow_provider
  end

  def import
    Rails.logger.info "LunchflowItem::Importer - Starting import for item #{lunchflow_item.id}"

    # Step 1: Fetch all accounts from Lunchflow
    accounts_data = fetch_accounts_data
    return if accounts_data.nil?

    # Store raw payload
    lunchflow_item.upsert_lunchflow_snapshot!(accounts_data)

    # Step 2: Import accounts
    accounts_data[:accounts]&.each do |account_data|
      import_account(account_data)
    end

    # Step 3: Fetch transactions for each account
    lunchflow_item.lunchflow_accounts.each do |lunchflow_account|
      fetch_and_store_transactions(lunchflow_account)
    end
  end

  private

  def fetch_accounts_data
    begin
      accounts_data = lunchflow_provider.get_accounts
    rescue Provider::Lunchflow::LunchflowError => e
      # Handle authentication errors by marking item as requiring update
      if e.error_type == :unauthorized || e.error_type == :access_forbidden
        lunchflow_item.update!(status: :requires_update)
      end
      raise e
    end

    # Handle errors if present in response
    if accounts_data[:error].present?
      handle_error(accounts_data[:error])
      return nil
    end

    accounts_data
  end

  def import_account(account_data)
    account_id = account_data[:id]

    # Validate required account_id to prevent duplicate creation
    return if account_id.blank?

    lunchflow_account = lunchflow_item.lunchflow_accounts.find_or_initialize_by(
      account_id: account_id.to_s
    )

    lunchflow_account.upsert_lunchflow_snapshot!(account_data)
    lunchflow_account.save!
  end

  def fetch_and_store_transactions(lunchflow_account)
    begin
      start_date = determine_sync_start_date
      Rails.logger.info "LunchflowItem::Importer - Fetching transactions for account #{lunchflow_account.account_id} from #{start_date}"

      # Fetch transactions
      transactions_data = lunchflow_provider.get_account_transactions(
        lunchflow_account.account_id,
        start_date: start_date
      )

      Rails.logger.info "LunchflowItem::Importer - Fetched #{transactions_data[:transactions]&.count || 0} transactions for account #{lunchflow_account.account_id}"

      # Store transactions in the account
      if transactions_data[:transactions].present?
        # Merge with existing transactions to avoid duplicates
        existing_transactions = lunchflow_account.raw_transactions_payload.to_a
        merged_transactions = (existing_transactions + transactions_data[:transactions]).uniq do |tx|
          tx = tx.with_indifferent_access
          tx[:id]
        end

        Rails.logger.info "LunchflowItem::Importer - Storing #{merged_transactions.count} transactions (#{existing_transactions.count} existing + #{transactions_data[:transactions].count} new) for account #{lunchflow_account.account_id}"
        lunchflow_account.upsert_lunchflow_transactions_snapshot!(merged_transactions)
      else
        Rails.logger.info "LunchflowItem::Importer - No transactions to store for account #{lunchflow_account.account_id}"
      end

      # Fetch and update balance
      fetch_and_update_balance(lunchflow_account)
    rescue Provider::Lunchflow::LunchflowError => e
      Rails.logger.error "Failed to fetch data for Lunchflow account #{lunchflow_account.id}: #{e.message}"
      # Don't fail the entire import if one account's data fetch fails
    end
  end

  def fetch_and_update_balance(lunchflow_account)
    balance_data = lunchflow_provider.get_account_balance(lunchflow_account.account_id)

    if balance_data[:balance].present?
      balance_info = balance_data[:balance]
      lunchflow_account.update!(
        current_balance: balance_info[:amount],
        currency: balance_info[:currency] || lunchflow_account.currency
      )
    end
  rescue Provider::Lunchflow::LunchflowError => e
    Rails.logger.error "Failed to fetch balance for Lunchflow account #{lunchflow_account.id}: #{e.message}"
    # Don't fail if balance fetch fails
  end

  def determine_sync_start_date
    # For the first sync, get data from the past 90 days
    unless lunchflow_item.last_synced_at
      return 90.days.ago
    end

    # For subsequent syncs, fetch from last sync date with a buffer
    lunchflow_item.last_synced_at - 7.days
  end

  def handle_error(error_message)
    # Mark item as requiring update for authentication-related errors
    needs_update = error_message.downcase.include?("authentication") ||
                   error_message.downcase.include?("unauthorized") ||
                   error_message.downcase.include?("api key")

    if needs_update
      lunchflow_item.update!(status: :requires_update)
    end

    raise Provider::Lunchflow::LunchflowError.new(
      "Lunchflow API error: #{error_message}",
      :api_error
    )
  end
end
