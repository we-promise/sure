# Imports wallet data from CoinStats API for linked accounts.
# Fetches balances and transactions, then updates local records.
class CoinstatsItem::Importer
  include CoinstatsTransactionIdentifiable

  attr_reader :coinstats_item, :coinstats_provider

  # @param coinstats_item [CoinstatsItem] Item containing accounts to import
  # @param coinstats_provider [Provider::Coinstats] API client instance
  def initialize(coinstats_item, coinstats_provider:)
    @coinstats_item = coinstats_item
    @coinstats_provider = coinstats_provider
  end

  # Imports balance and transaction data for all linked accounts.
  # @return [Hash] Result with :success, :accounts_updated, :transactions_imported
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

    # Fetch balance data using bulk endpoint
    bulk_balance_data = fetch_balances_for_accounts(linked_accounts)

    # Fetch transaction data using bulk endpoint
    bulk_transactions_data = fetch_transactions_for_accounts(linked_accounts)

    linked_accounts.each do |coinstats_account|
      begin
        result = update_account(coinstats_account, bulk_balance_data: bulk_balance_data, bulk_transactions_data: bulk_transactions_data)
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

    # Fetch balance data for all linked accounts using the bulk endpoint
    # @param linked_accounts [Array<CoinstatsAccount>] Accounts to fetch balances for
    # @return [Array<Hash>, nil] Bulk balance data, or nil on error
    def fetch_balances_for_accounts(linked_accounts)
      # Extract unique wallet addresses and blockchains
      wallets = linked_accounts.filter_map do |account|
        raw = account.raw_payload || {}
        address = raw["address"] || raw[:address]
        blockchain = raw["blockchain"] || raw[:blockchain]
        next unless address.present? && blockchain.present?

        { address: address, blockchain: blockchain }
      end.uniq { |w| [ w[:address].downcase, w[:blockchain].downcase ] }

      return nil if wallets.empty?

      Rails.logger.info "CoinstatsItem::Importer - Fetching balances for #{wallets.size} wallet(s) via bulk endpoint"
      # Build comma-separated string in format "blockchain:address"
      wallets_param = wallets.map { |w| "#{w[:blockchain]}:#{w[:address]}" }.join(",")
      response = coinstats_provider.get_wallet_balances(wallets_param)
      response.success? ? response.data : nil
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - Bulk balance fetch failed: #{e.message}"
      nil
    end

    # Fetch transaction data for all linked accounts using the bulk endpoint
    # @param linked_accounts [Array<CoinstatsAccount>] Accounts to fetch transactions for
    # @return [Array<Hash>, nil] Bulk transaction data, or nil on error
    def fetch_transactions_for_accounts(linked_accounts)
      # Extract unique wallet addresses and blockchains
      wallets = linked_accounts.filter_map do |account|
        raw = account.raw_payload || {}
        address = raw["address"] || raw[:address]
        blockchain = raw["blockchain"] || raw[:blockchain]
        next unless address.present? && blockchain.present?

        { address: address, blockchain: blockchain }
      end.uniq { |w| [ w[:address].downcase, w[:blockchain].downcase ] }

      return nil if wallets.empty?

      Rails.logger.info "CoinstatsItem::Importer - Fetching transactions for #{wallets.size} wallet(s) via bulk endpoint"
      # Build comma-separated string in format "blockchain:address"
      wallets_param = wallets.map { |w| "#{w[:blockchain]}:#{w[:address]}" }.join(",")
      response = coinstats_provider.get_wallet_transactions(wallets_param)
      response.success? ? response.data : nil
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - Bulk transaction fetch failed: #{e.message}"
      nil
    end

    # Updates a single account with balance and transaction data.
    # @param coinstats_account [CoinstatsAccount] Account to update
    # @param bulk_balance_data [Array, nil] Pre-fetched balance data
    # @param bulk_transactions_data [Array, nil] Pre-fetched transaction data
    # @return [Hash] Result with :success and :transactions_count
    def update_account(coinstats_account, bulk_balance_data:, bulk_transactions_data:)
      # Get the wallet address and blockchain from the raw payload
      raw = coinstats_account.raw_payload || {}
      address = raw["address"] || raw[:address]
      blockchain = raw["blockchain"] || raw[:blockchain]

      unless address.present? && blockchain.present?
        Rails.logger.warn "CoinstatsItem::Importer - Missing address or blockchain for account #{coinstats_account.id}. Address: #{address.inspect}, Blockchain: #{blockchain.inspect}"
        return { success: false, error: "Missing address or blockchain" }
      end

      # Extract balance data for this specific wallet from the bulk response
      balance_data = if bulk_balance_data.present?
        coinstats_provider.extract_wallet_balance(bulk_balance_data, address, blockchain)
      else
        []
      end

      # Update the coinstats account with new balance data
      coinstats_account.upsert_coinstats_snapshot!(normalize_balance_data(balance_data, coinstats_account))

      # Extract and merge transactions from bulk response
      transactions_count = fetch_and_merge_transactions(coinstats_account, address, blockchain, bulk_transactions_data)

      { success: true, transactions_count: transactions_count }
    end

    # Extracts and merges new transactions for an account.
    # Deduplicates by transaction ID to avoid duplicate imports.
    # @param coinstats_account [CoinstatsAccount] Account to update
    # @param address [String] Wallet address
    # @param blockchain [String] Blockchain identifier
    # @param bulk_transactions_data [Array, nil] Pre-fetched transaction data
    # @return [Integer] Number of relevant transactions found
    def fetch_and_merge_transactions(coinstats_account, address, blockchain, bulk_transactions_data)
      # Extract transactions for this specific wallet from the bulk response
      transactions_data = if bulk_transactions_data.present?
        coinstats_provider.extract_wallet_transactions(bulk_transactions_data, address, blockchain)
      else
        []
      end

      new_transactions = transactions_data.is_a?(Array) ? transactions_data : (transactions_data[:result] || [])
      return 0 if new_transactions.empty?

      # Filter transactions to only include those relevant to this coin/token
      coin_id = coinstats_account.account_id
      relevant_transactions = filter_transactions_by_coin(new_transactions, coin_id)
      return 0 if relevant_transactions.empty?

      # Get existing transactions (already extracted as array)
      existing_transactions = coinstats_account.raw_transactions_payload.to_a

      # Build a set of existing transaction IDs to avoid duplicates
      existing_ids = existing_transactions.map { |tx| extract_coinstats_transaction_id(tx) }.compact.to_set

      # Filter to only new transactions
      transactions_to_add = relevant_transactions.select do |tx|
        tx_id = extract_coinstats_transaction_id(tx)
        tx_id.present? && !existing_ids.include?(tx_id)
      end

      if transactions_to_add.any?
        # Merge new transactions with existing ones
        merged_transactions = existing_transactions + transactions_to_add
        coinstats_account.upsert_coinstats_transactions_snapshot!(merged_transactions)
        Rails.logger.info "CoinstatsItem::Importer - Added #{transactions_to_add.count} new transactions for account #{coinstats_account.id}"
      end

      relevant_transactions.count
    end

    # Filter transactions to only include those relevant to a specific coin
    # Transactions can be matched by:
    # - coinData.symbol matching the coin (case-insensitive)
    # - transactions[].items[].coin.id matching the coin_id
    # @param transactions [Array<Hash>] Array of transaction objects
    # @param coin_id [String] The coin ID to filter by (e.g., "chainlink", "ethereum")
    # @return [Array<Hash>] Filtered transactions
    def filter_transactions_by_coin(transactions, coin_id)
      return [] if coin_id.blank?

      coin_id_downcase = coin_id.to_s.downcase

      transactions.select do |tx|
        tx = tx.with_indifferent_access

        # Check nested transactions items for coin match
        inner_transactions = tx[:transactions] || []
        inner_transactions.any? do |inner_tx|
          inner_tx = inner_tx.with_indifferent_access
          items = inner_tx[:items] || []
          items.any? do |item|
            item = item.with_indifferent_access
            coin = item[:coin]
            next false unless coin.present?

            coin = coin.with_indifferent_access
            coin[:id]&.downcase == coin_id_downcase
          end
        end
      end
    end

    # Normalizes API balance data to a consistent schema for storage.
    # @param balance_data [Array<Hash>] Raw token balances from API
    # @param coinstats_account [CoinstatsAccount] Account for context
    # @return [Hash] Normalized snapshot with id, balance, address, etc.
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

    # Finds the token in balance_data that matches this account.
    # Matches by account_id (coinId) first, then falls back to name.
    # @param balance_data [Array<Hash>] Token balances from API
    # @param coinstats_account [CoinstatsAccount] Account to match
    # @return [Hash, nil] Matching token data or nil
    def find_matching_token(balance_data, coinstats_account)
      tokens = normalize_tokens(balance_data).map(&:with_indifferent_access)
      return nil if tokens.empty?

      # First try to match by account_id (coinId) if available
      if coinstats_account.account_id.present?
        account_id = coinstats_account.account_id.to_s
        matching = tokens.find do |token|
          token_id = (token[:coinId] || token[:id])&.to_s
          token_id == account_id
        end
        return matching if matching
      end

      # Fall back to matching by name (handles legacy accounts without account_id)
      account_name = coinstats_account.name&.downcase
      return nil if account_name.blank?

      tokens.find do |token|
        token_name = token[:name]&.to_s&.downcase
        token_symbol = token[:symbol]&.to_s&.downcase

        # Match if account name contains the token name or symbol, or vice versa
        account_name.include?(token_name) || token_name.include?(account_name) ||
          (token_symbol.present? && (account_name.include?(token_symbol) || token_symbol == account_name))
      end
    end

    # Normalizes various response formats to an array of tokens.
    # @param balance_data [Array, Hash, nil] Raw balance response
    # @return [Array<Hash>] Array of token hashes
    def normalize_tokens(balance_data)
      if balance_data.is_a?(Array)
        balance_data
      elsif balance_data.is_a?(Hash)
        balance_data[:result] || balance_data[:tokens] || []
      else
        []
      end
    end

    # Calculates USD balance from token amount and price.
    # @param token [Hash, nil] Token with :amount/:balance and :price/:priceUsd
    # @return [Float] Balance in USD (0 if token is nil)
    def calculate_token_balance(token)
      return 0 if token.blank?

      amount = token[:amount] || token[:balance] || 0
      price = token[:price] || token[:priceUsd] || 0
      (amount.to_f * price.to_f)
    end
end
