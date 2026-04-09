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
    sync_exchange_accounts!

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

    wallet_accounts = linked_accounts.select(&:wallet_source?)
    exchange_accounts = linked_accounts.select(&:exchange_source?)

    accounts_failed += sync_defi_for_wallets!(wallet_accounts)

    bulk_balance_data = fetch_balances_for_accounts(wallet_accounts)
    bulk_transactions_data = fetch_transactions_for_accounts(wallet_accounts)
    portfolio_coins_data = fetch_portfolio_coins_for_exchange(exchange_accounts)
    portfolio_transactions_data = fetch_portfolio_transactions_for_exchange(exchange_accounts)

    linked_accounts.each do |coinstats_account|
      begin
        result =
          if coinstats_account.exchange_source?
            update_exchange_account(
              coinstats_account,
              portfolio_coins_data: portfolio_coins_data,
              portfolio_transactions_data: portfolio_transactions_data
            )
          elsif coinstats_account.defi_source?
            # DeFi/staking accounts are kept up to date by sync_defi_for_wallets! above
            { success: true, transactions_count: 0 }
          else
            update_wallet_account(
              coinstats_account,
              bulk_balance_data: bulk_balance_data,
              bulk_transactions_data: bulk_transactions_data
            )
          end
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

    def sync_exchange_accounts!
      return unless coinstats_item.exchange_configured?
      return if coinstats_item.coinstats_accounts.any?(&:exchange_source?)

      exchange_portfolio_configurations.each do |config|
        portfolio_coins = coinstats_provider.list_portfolio_coins(portfolio_id: config[:portfolio_id])
        coinstats_account = exchange_portfolio_account_manager.upsert_account!(
          coins_data: portfolio_coins,
          portfolio_id: config[:portfolio_id],
          connection_id: config[:connection_id],
          exchange_name: config[:exchange_name],
          account_name: config[:exchange_name],
          institution_logo: coinstats_item.raw_institution_payload.to_h.with_indifferent_access[:icon]
        )
        exchange_portfolio_account_manager.ensure_local_account!(coinstats_account)
      end
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - Exchange account discovery failed: #{e.message}"
    end

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

    def fetch_portfolio_coins_for_exchange(linked_accounts)
      return {} if linked_accounts.empty? && !coinstats_item.exchange_configured?

      exchange_portfolio_configurations(linked_accounts).each_with_object({}) do |config, results|
        Rails.logger.info "CoinstatsItem::Importer - Fetching portfolio coins for CoinStats exchange #{config[:portfolio_id]}"
        results[config[:portfolio_id]] = coinstats_provider.list_portfolio_coins(portfolio_id: config[:portfolio_id])
      end
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - Portfolio coins fetch failed: #{e.message}"
      {}
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

    def fetch_portfolio_transactions_for_exchange(linked_accounts)
      return {} if linked_accounts.empty? && !coinstats_item.exchange_configured?

      from = coinstats_item.sync_start_date&.iso8601

      exchange_portfolio_configurations(linked_accounts).each_with_object({}) do |config, results|
        Rails.logger.info "CoinstatsItem::Importer - Fetching exchange transactions for CoinStats exchange #{config[:portfolio_id]} in #{family_currency}"

        begin
          coinstats_provider.sync_exchange(portfolio_id: config[:portfolio_id])

          results[config[:portfolio_id]] = coinstats_provider.list_exchange_transactions(
            portfolio_id: config[:portfolio_id],
            currency: family_currency,
            from: from
          )
        rescue => e
          Rails.logger.warn "CoinstatsItem::Importer - Exchange transactions fetch failed for #{config[:portfolio_id]}: #{e.message}; falling back to portfolio transactions"

          begin
            coinstats_provider.sync_portfolio(portfolio_id: config[:portfolio_id])
            results[config[:portfolio_id]] = coinstats_provider.list_portfolio_transactions(
              portfolio_id: config[:portfolio_id],
              currency: family_currency,
              from: from
            )
          rescue => fallback_error
            Rails.logger.warn "CoinstatsItem::Importer - Portfolio transaction fallback failed for #{config[:portfolio_id]}: #{fallback_error.message}"
            results[config[:portfolio_id]] = []
          end
        end
      end
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - Exchange transactions fetch failed: #{e.message}"
      {}
    end

    # Updates a single account with balance and transaction data.
    # @param coinstats_account [CoinstatsAccount] Account to update
    # @param bulk_balance_data [Array, nil] Pre-fetched balance data
    # @param bulk_transactions_data [Array, nil] Pre-fetched transaction data
    # @return [Hash] Result with :success and :transactions_count
    def update_wallet_account(coinstats_account, bulk_balance_data:, bulk_transactions_data:)
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

    def update_exchange_account(coinstats_account, portfolio_coins_data:, portfolio_transactions_data:)
      portfolio_id = exchange_portfolio_id_for(coinstats_account)
      balance_data = portfolio_coins_data[portfolio_id]

      if coinstats_account.exchange_portfolio_account?
        if !balance_data.nil?
          coinstats_account.upsert_coinstats_snapshot!(
            normalize_exchange_portfolio_data(balance_data, coinstats_account, portfolio_id: portfolio_id)
          )
        else
          Rails.logger.warn "CoinstatsItem::Importer - Missing exchange portfolio coin data for account #{coinstats_account.id} (portfolio #{portfolio_id}); preserving previous snapshot"
        end
      else
        matching_coin = find_matching_portfolio_coin(balance_data, coinstats_account)

        if matching_coin.present?
          coinstats_account.upsert_coinstats_snapshot!(
            normalize_portfolio_coin_data(matching_coin, coinstats_account, portfolio_id: portfolio_id)
          )
        else
          Rails.logger.warn "CoinstatsItem::Importer - No matching exchange coin found for account #{coinstats_account.id} (#{coinstats_account.account_id}) in portfolio #{portfolio_id}; preserving previous snapshot"
        end
      end

      transactions_count = fetch_and_merge_portfolio_transactions(coinstats_account, portfolio_transactions_data[portfolio_id])

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

    def fetch_and_merge_portfolio_transactions(coinstats_account, portfolio_transactions_data)
      return 0 if portfolio_transactions_data.blank?

      relevant_transactions =
        if coinstats_account.exchange_portfolio_account?
          Array(portfolio_transactions_data)
        else
          filter_transactions_by_coin(portfolio_transactions_data, coinstats_account.account_id)
        end
      return 0 if relevant_transactions.empty?

      existing_transactions = coinstats_account.raw_transactions_payload.to_a
      existing_ids = existing_transactions.map { |tx| extract_coinstats_transaction_id(tx) }.compact.to_set

      transactions_to_add = relevant_transactions.select do |tx|
        tx_id = extract_coinstats_transaction_id(tx)
        tx_id.present? && !existing_ids.include?(tx_id)
      end

      if transactions_to_add.any?
        merged_transactions = existing_transactions + transactions_to_add
        coinstats_account.upsert_coinstats_transactions_snapshot!(merged_transactions)
        Rails.logger.info "CoinstatsItem::Importer - Added #{transactions_to_add.count} new exchange transactions for account #{coinstats_account.id}"
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
        coin_identifier = tx.dig(:coinData, :identifier)&.to_s&.downcase

        # Check nested transactions items for coin match
        inner_transactions = tx[:transactions] || []
        matches_nested_item = inner_transactions.any? do |inner_tx|
          inner_tx = inner_tx.with_indifferent_access
          items = inner_tx[:items] || []
          items.any? do |item|
            item = item.with_indifferent_access
            coin = item[:coin]
            next false unless coin.present?

            coin = coin.with_indifferent_access
            coin[:id]&.downcase == coin_id_downcase ||
              coin[:identifier]&.downcase == coin_id_downcase ||
              coin[:symbol]&.downcase == coin_id_downcase
          end
        end

        transfer_transactions = tx[:transfers] || []
        matches_transfer_item = transfer_transactions.any? do |transfer_tx|
          transfer_tx = transfer_tx.with_indifferent_access
          items = transfer_tx[:items] || []
          items.any? do |item|
            item = item.with_indifferent_access
            coin = item[:coin]
            next false unless coin.present?

            coin = coin.with_indifferent_access
            coin[:id]&.downcase == coin_id_downcase ||
              coin[:identifier]&.downcase == coin_id_downcase ||
              coin[:symbol]&.downcase == coin_id_downcase
          end
        end

        coin_identifier == coin_id_downcase || matches_nested_item || matches_transfer_item
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

      source_snapshot = (matching_token || {}).to_h.with_indifferent_access

      {
        # Use existing account_id if set, otherwise extract from matching token
        id: coinstats_account.account_id.presence || matching_token&.dig(:coinId) || matching_token&.dig(:id),
        name: coinstats_account.name,
        balance: coinstats_account.inferred_current_balance(source_snapshot),
        currency: coinstats_account.inferred_currency(source_snapshot),
        address: existing_raw["address"] || existing_raw[:address],
        blockchain: existing_raw["blockchain"] || existing_raw[:blockchain],
        # Extract logo from the matching token
        institution_logo: matching_token&.dig(:imgUrl),
        # Preserve original data
        raw_balance_data: balance_data
      }.merge(source_snapshot.slice(:amount, :count, :price, :priceUsd, :symbol, :coinId, :isFiat, :imgUrl))
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

    def find_matching_portfolio_coin(balance_data, coinstats_account)
      Array(balance_data).map(&:with_indifferent_access).find do |coin_data|
        coin = coin_data[:coin].to_h.with_indifferent_access
        identifier = coin[:identifier].presence || coin_data[:coinId].presence
        symbol = coin[:symbol].presence || coin_data[:symbol].presence
        base_name = coinstats_account.name.to_s.sub(/\s+\([^)]*\)\z/, "").downcase

        identifier.to_s.casecmp?(coinstats_account.account_id.to_s) ||
          symbol.to_s.casecmp?(coinstats_account.account_id.to_s) ||
          symbol.to_s.casecmp?(coinstats_account.asset_symbol.to_s) ||
          coin[:name].to_s.downcase == base_name
      end
    end

    def normalize_portfolio_coin_data(balance_data, coinstats_account, portfolio_id:)
      existing_raw = coinstats_account.raw_payload.to_h.with_indifferent_access
      portfolio_coin = balance_data.to_h.with_indifferent_access
      coin = portfolio_coin[:coin].to_h.with_indifferent_access
      source_snapshot = {
        source: existing_raw[:source] || "exchange",
        portfolio_id: portfolio_id,
        connection_id: existing_raw[:connection_id] || coinstats_item.exchange_connection_id,
        exchange_name: existing_raw[:exchange_name] || exchange_display_name,
        coin: coin
      }.merge(portfolio_coin)

      {
        id: coin[:identifier].presence || coinstats_account.account_id,
        name: coinstats_account.name,
        balance: coinstats_account.inferred_current_balance(source_snapshot),
        currency: coinstats_account.inferred_currency(source_snapshot),
        provider: existing_raw[:exchange_name].presence || exchange_display_name,
        account_status: "active",
        portfolio_id: portfolio_id,
        connection_id: existing_raw[:connection_id] || coinstats_item.exchange_connection_id,
        institution_logo: coin[:icon],
        raw_balance_data: portfolio_coin
      }.merge(existing_raw.slice(:source, :exchange_name))
       .merge(portfolio_coin.slice(:coin, :count, :price, :averageBuy, :averageSell, :profit, :profitPercent, :coinId, :isFiat))
    end

    def normalize_exchange_portfolio_data(balance_data, coinstats_account, portfolio_id:)
      existing_raw = coinstats_account.raw_payload.to_h.with_indifferent_access
      coins = Array(balance_data).map { |coin| coin.with_indifferent_access.to_h }

      snapshot = existing_raw.merge(
        source: "exchange",
        portfolio_account: true,
        portfolio_id: portfolio_id,
        connection_id: existing_raw[:connection_id] || coinstats_item.exchange_connection_id,
        exchange_name: existing_raw[:exchange_name] || exchange_display_name,
        name: coinstats_account.name,
        institution_logo: existing_raw[:institution_logo].presence || coinstats_item.raw_institution_payload.to_h.with_indifferent_access[:icon],
        coins: coins
      )

      {
        id: coinstats_account.account_id.presence || exchange_portfolio_account_manager.portfolio_account_id(portfolio_id),
        name: coinstats_account.name,
        balance: coinstats_account.inferred_current_balance(snapshot),
        currency: coinstats_account.inferred_currency(snapshot),
        provider: snapshot[:exchange_name],
        account_status: "active",
        portfolio_id: portfolio_id,
        connection_id: snapshot[:connection_id],
        institution_logo: snapshot[:institution_logo],
        portfolio_account: true,
        coins: coins
      }.merge(snapshot.slice(:source, :exchange_name))
    end

    def exchange_display_name
      coinstats_item.institution_name.presence || coinstats_item.exchange_connection_id.to_s.titleize
    end

    def exchange_portfolio_account_manager
      @exchange_portfolio_account_manager ||= CoinstatsItem::ExchangePortfolioAccountManager.new(coinstats_item)
    end

    def exchange_portfolio_configurations(linked_accounts = [])
      configurations = []

      if coinstats_item.exchange_configured?
        configurations << {
          portfolio_id: coinstats_item.exchange_portfolio_id,
          connection_id: coinstats_item.exchange_connection_id,
          exchange_name: exchange_display_name
        }
      end

      Array(linked_accounts).select(&:exchange_source?).each do |account|
        raw = account.raw_payload.to_h.with_indifferent_access
        portfolio_id = raw[:portfolio_id].presence || account.wallet_address.presence
        next if portfolio_id.blank?

        configurations << {
          portfolio_id: portfolio_id,
          connection_id: raw[:connection_id].presence || coinstats_item.exchange_connection_id,
          exchange_name: raw[:exchange_name].presence || exchange_display_name
        }
      end

      configurations.uniq { |config| config[:portfolio_id] }
    end

    def exchange_portfolio_id_for(coinstats_account)
      raw = coinstats_account.raw_payload.to_h.with_indifferent_access
      raw[:portfolio_id].presence || coinstats_account.wallet_address.presence || coinstats_item.exchange_portfolio_id
    end

    def family_currency
      coinstats_item.family.currency.presence || "USD"
    end

    # Syncs DeFi/staking positions for all unique wallet addresses by delegating
    # to DefiAccountManager, which owns discovery, upsert, and zero-out logic.
    # Returns the number of wallets that failed to sync so the caller can track failures.
    def sync_defi_for_wallets!(wallet_accounts)
      # Include existing DeFi accounts as address sources so staking positions stay
      # current even if the parent wallet account has been removed.
      defi_accounts = coinstats_item.coinstats_accounts.joins(:account_provider).select(&:defi_source?)

      unique_wallets = (wallet_accounts + defi_accounts).uniq(&:id).filter_map do |account|
        raw = account.raw_payload.to_h.with_indifferent_access
        next unless raw[:address].present? && raw[:blockchain].present?

        { address: raw[:address], blockchain: raw[:blockchain] }
      end.uniq { |w| [ w[:address].downcase, w[:blockchain].downcase ] }

      return 0 if unique_wallets.empty?

      manager = CoinstatsItem::DefiAccountManager.new(coinstats_item)
      failed = 0

      unique_wallets.each do |wallet|
        result = manager.sync_wallet!(address: wallet[:address], blockchain: wallet[:blockchain], provider: coinstats_provider)
        failed += 1 unless result
      end

      failed
    rescue => e
      Rails.logger.warn "CoinstatsItem::Importer - DeFi sync failed: #{e.message}"
      0
    end
end
