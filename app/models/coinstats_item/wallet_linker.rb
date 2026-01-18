# frozen_string_literal: true

# Links a cryptocurrency wallet to CoinStats by fetching token balances
# and creating corresponding accounts for each token found.
class CoinstatsItem::WalletLinker
  attr_reader :coinstats_item, :address, :blockchain

  Result = Struct.new(:success?, :created_count, :errors, keyword_init: true)

  # @param coinstats_item [CoinstatsItem] Parent item with API credentials
  # @param address [String] Wallet address to link
  # @param blockchain [String] Blockchain network identifier
  def initialize(coinstats_item, address:, blockchain:)
    @coinstats_item = coinstats_item
    @address = address
    @blockchain = blockchain
  end

  # Fetches wallet balances and creates accounts for each token.
  # @return [Result] Success status, created count, and any errors
  def link
    balance_data = fetch_balance_data
    tokens = normalize_tokens(balance_data)

    return Result.new(success?: false, created_count: 0, errors: [ "No tokens found for wallet" ]) if tokens.empty?

    created_count = 0
    errors = []

    tokens.each do |token_data|
      result = create_account_from_token(token_data)
      if result[:success]
        created_count += 1
      else
        errors << result[:error]
      end
    end

    # Trigger a sync if we created any accounts
    coinstats_item.sync_later if created_count > 0

    Result.new(success?: created_count > 0, created_count: created_count, errors: errors)
  end

  private

    # Fetches balance data for this wallet from CoinStats API.
    # @return [Array<Hash>] Token balances for the wallet
    def fetch_balance_data
      provider = Provider::Coinstats.new(coinstats_item.api_key)
      wallets_param = "#{blockchain}:#{address}"
      response = provider.get_wallet_balances(wallets_param)

      return [] unless response.success?

      provider.extract_wallet_balance(response.data, address, blockchain)
    end

    # Normalizes various balance data formats to an array of tokens.
    # @param balance_data [Array, Hash, Object] Raw balance response
    # @return [Array<Hash>] Normalized array of token data
    def normalize_tokens(balance_data)
      if balance_data.is_a?(Array)
        balance_data
      elsif balance_data.is_a?(Hash)
        balance_data[:result] || balance_data[:tokens] || [ balance_data ]
      elsif balance_data.present?
        [ balance_data ]
      else
        []
      end
    end

    # Creates a CoinstatsAccount and linked Account for a token.
    # @param token_data [Hash] Token balance data from API
    # @return [Hash] Result with :success and optional :error
    def create_account_from_token(token_data)
      token = token_data.with_indifferent_access
      account_name = build_account_name(token)
      current_balance = calculate_balance(token)
      token_id = (token[:coinId] || token[:id])&.to_s

      ActiveRecord::Base.transaction do
        coinstats_account = coinstats_item.coinstats_accounts.create!(
          name: account_name,
          currency: "USD",
          current_balance: current_balance,
          account_id: token_id,
          wallet_address: address
        )

        # Store wallet metadata for future syncs
        snapshot = build_snapshot(token, current_balance)
        coinstats_account.upsert_coinstats_snapshot!(snapshot)

        account = coinstats_item.family.accounts.create!(
          accountable: Crypto.new,
          name: account_name,
          balance: current_balance,
          cash_balance: current_balance,
          currency: coinstats_account.currency,
          status: "active"
        )

        AccountProvider.create!(account: account, provider: coinstats_account)

        { success: true }
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("CoinstatsItem::WalletLinker - Failed to create account: #{e.message}")
      { success: false, error: "Failed to create #{account_name || 'account'}: #{e.message}" }
    rescue => e
      Rails.logger.error("CoinstatsItem::WalletLinker - Unexpected error: #{e.class} - #{e.message}")
      { success: false, error: "Unexpected error: #{e.message}" }
    end

    # Builds a display name for the account from token and address.
    # @param token [Hash] Token data with :name
    # @return [String] Human-readable account name
    def build_account_name(token)
      token_name = token[:name].to_s.strip
      truncated_address = address.present? ? "#{address.first(4)}...#{address.last(4)}" : nil

      if token_name.present? && truncated_address.present?
        "#{token_name} (#{truncated_address})"
      elsif token_name.present?
        token_name
      elsif truncated_address.present?
        "#{blockchain.capitalize} (#{truncated_address})"
      else
        "Crypto Wallet"
      end
    end

    # Calculates USD balance from token amount and price.
    # @param token [Hash] Token data with :amount/:balance and :price
    # @return [Float] Balance in USD
    def calculate_balance(token)
      amount = token[:amount] || token[:balance] || token[:current_balance] || 0
      price = token[:price] || 0
      (amount.to_f * price.to_f)
    end

    # Builds snapshot hash for storing in CoinstatsAccount.
    # @param token [Hash] Token data from API
    # @param current_balance [Float] Calculated USD balance
    # @return [Hash] Snapshot with balance, address, and metadata
    def build_snapshot(token, current_balance)
      token.to_h.merge(
        id: (token[:coinId] || token[:id])&.to_s,
        balance: current_balance,
        currency: "USD",
        address: address,
        blockchain: blockchain,
        institution_logo: token[:imgUrl]
      )
    end
end
