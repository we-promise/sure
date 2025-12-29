class CoinstatsItem::Importer
  include CoinstatsTransactionIdentifiable

  attr_reader :coinstats_item, :coinstats_provider

  def initialize(coinstats_item, coinstats_provider:)
    @coinstats_item = coinstats_item
    @coinstats_provider = coinstats_provider
  end

  def import
    Rails.logger.info "CoinstatsItem::Importer - Starting import for item #{coinstats_item.id}"

    # CoinStats works differently from bank providers - wallets are added manually
    # via the setup_accounts flow. During sync, we just update existing linked accounts.

    # Get all linked coinstats accounts (ones with account_provider associations)
    linked_accounts = coinstats_item.coinstats_accounts
                                    .joins(:account_provider)
                                    .includes(:account)

    if linked_accounts.empty?
      Rails.logger.info "CoinstatsItem::Importer - No linked accounts to sync for item #{coinstats_item.id}"
      return { success: true, accounts_updated: 0, transactions_imported: 0 }
    end

    accounts_updated = 0
    accounts_failed = 0
    transactions_imported = 0

    linked_accounts.each do |coinstats_account|
      begin
        result = update_account(coinstats_account)
        accounts_updated += 1 if result[:success]
        transactions_imported += result[:transactions_count] || 0
      rescue => e
        accounts_failed += 1
        Rails.logger.error "CoinstatsItem::Importer - Failed to update account #{coinstats_account.id}: #{e.message}"
      end
    end

    Rails.logger.info "CoinstatsItem::Importer - Updated #{accounts_updated} accounts (#{accounts_failed} failed), #{transactions_imported} transactions"

    {
      success: accounts_failed == 0,
      accounts_updated: accounts_updated,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported
    }
  end

  private

    def update_account(coinstats_account)
      # Get the wallet address and blockchain from the raw payload
      raw = coinstats_account.raw_payload || {}
      address = raw["address"] || raw[:address]
      blockchain = raw["blockchain"] || raw[:blockchain]

      unless address.present? && blockchain.present?
        Rails.logger.warn "CoinstatsItem::Importer - Missing address or blockchain for account #{coinstats_account.id}. Address: #{address.inspect}, Blockchain: #{blockchain.inspect}"
        return { success: false, error: "Missing address or blockchain" }
      end

      # Fetch current balance from CoinStats API
      balance_data = coinstats_provider.get_wallet_balance(address, blockchain)

      # Update the coinstats account with new balance data
      coinstats_account.upsert_coinstats_snapshot!(normalize_balance_data(balance_data, coinstats_account))

      # Fetch and merge transactions
      transactions_count = fetch_and_merge_transactions(coinstats_account, address, blockchain)

      { success: true, transactions_count: transactions_count }
    end

    def fetch_and_merge_transactions(coinstats_account, address, blockchain)
      transactions_data = coinstats_provider.get_wallet_transactions(address, blockchain)

      # get_wallet_transactions returns a flat array of all transactions (paginated internally)
      new_transactions = transactions_data.is_a?(Array) ? transactions_data : (transactions_data[:result] || [])
      return 0 if new_transactions.empty?

      # Get existing transactions (already extracted as array)
      existing_transactions = coinstats_account.raw_transactions_payload.to_a

      # Build a set of existing transaction IDs to avoid duplicates
      existing_ids = existing_transactions.map { |tx| extract_coinstats_transaction_id(tx) }.compact.to_set

      # Filter to only new transactions
      transactions_to_add = new_transactions.select do |tx|
        tx_id = extract_coinstats_transaction_id(tx)
        tx_id.present? && !existing_ids.include?(tx_id)
      end

      if transactions_to_add.any?
        # Merge new transactions with existing ones
        merged_transactions = existing_transactions + transactions_to_add
        coinstats_account.upsert_coinstats_transactions_snapshot!(merged_transactions)
        Rails.logger.info "CoinstatsItem::Importer - Added #{transactions_to_add.count} new transactions for account #{coinstats_account.id}"
      end

      new_transactions.count
    rescue Provider::Coinstats::RateLimitError => e
      Rails.logger.warn "CoinstatsItem::Importer - Rate limited fetching transactions for #{coinstats_account.id}: #{e.message}"
      0
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - Failed to fetch transactions for #{coinstats_account.id}: #{e.message}"
      # Continue without transactions - balance update is more important
      0
    end

    def normalize_balance_data(balance_data, coinstats_account)
      # CoinStats get_wallet_balance returns an array of token balances directly
      # Normalize it to match our expected schema
      # Preserve existing address/blockchain from raw_payload
      existing_raw = coinstats_account.raw_payload || {}

      # Find the matching token for this account to extract id, logo, and balance
      matching_token = find_matching_token(balance_data, coinstats_account)

      # Calculate balance from the matching token only, not all tokens
      # Each coinstats_account represents a single token/coin in the wallet
      token_balance = calculate_token_balance(matching_token)

      {
        # Use existing account_id if set, otherwise extract from matching token
        id: coinstats_account.account_id.presence || matching_token&.dig(:coinId) || matching_token&.dig(:id),
        name: coinstats_account.name,
        balance: token_balance,
        currency: "USD", # CoinStats returns values in USD
        address: existing_raw["address"] || existing_raw[:address],
        blockchain: existing_raw["blockchain"] || existing_raw[:blockchain],
        # Extract logo from the matching token
        institution_logo: matching_token&.dig(:imgUrl),
        # Preserve original data
        raw_balance_data: balance_data
      }
    end

    # Find the token in balance_data that matches this coinstats_account
    # Tries to match by account_id first, then falls back to name matching
    def find_matching_token(balance_data, coinstats_account)
      tokens = normalize_tokens(balance_data)
      return nil if tokens.empty?

      # First try to match by account_id (coinId) if available
      if coinstats_account.account_id.present?
        matching = tokens.find do |token|
          token = token.with_indifferent_access
          token_id = (token[:coinId] || token[:id])&.to_s
          token_id == coinstats_account.account_id.to_s
        end
        return matching&.with_indifferent_access if matching
      end

      # Fall back to matching by name (handles legacy accounts without account_id)
      account_name = coinstats_account.name&.downcase
      return nil if account_name.blank?

      matching = tokens.find do |token|
        token = token.with_indifferent_access
        token_name = token[:name]&.to_s&.downcase
        token_symbol = token[:symbol]&.to_s&.downcase

        # Match if account name contains the token name or symbol, or vice versa
        account_name.include?(token_name) || token_name.include?(account_name) ||
          (token_symbol.present? && (account_name.include?(token_symbol) || token_symbol == account_name))
      end

      matching&.with_indifferent_access
    end

    def normalize_tokens(balance_data)
      if balance_data.is_a?(Array)
        balance_data
      elsif balance_data.is_a?(Hash)
        balance_data[:result] || balance_data[:tokens] || []
      else
        []
      end
    end

    # Calculate balance for a single token
    # Used when syncing individual coinstats_accounts that each represent one token
    def calculate_token_balance(token)
      return 0 if token.blank?

      token = token.with_indifferent_access
      amount = token[:amount] || token[:balance] || 0
      price = token[:price] || token[:priceUsd] || 0
      (amount.to_f * price.to_f)
    end

    def calculate_total_balance(balance_data)
      # CoinStats get_wallet_balance returns an array of token balances directly
      # Each token has: amount, price (USD), symbol, name, etc.
      tokens = normalize_tokens(balance_data)
      return 0 if tokens.empty?

      tokens.sum do |token|
        token = token.with_indifferent_access
        # Calculate USD value: amount * price
        amount = token[:amount] || token[:balance] || 0
        price = token[:price] || token[:priceUsd] || 0
        (amount.to_f * price.to_f)
      end
    end
end
