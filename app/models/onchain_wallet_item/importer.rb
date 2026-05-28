# frozen_string_literal: true

class OnchainWalletItem::Importer
  SATS_PER_BTC = 100_000_000.to_d
  WEI_PER_ETH = 1_000_000_000_000_000_000.to_d

  attr_reader :onchain_wallet_item

  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
  end

  def import
    imported = 0
    snapshots = {}

    wallet_keys.each do |chain, address|
      if chain == "bitcoin"
        snapshots[address] = import_bitcoin_wallet(address)
      elsif chain == "ethereum"
        snapshots[address] = import_ethereum_wallet(address)
      end
      imported += 1
    end

    onchain_wallet_item.upsert_onchain_snapshot!({
      "wallets" => snapshots,
      "imported_at" => Time.current.iso8601
    })

    { success: true, wallets_imported: imported, accounts_imported: onchain_wallet_item.onchain_wallet_accounts.count }
  end

  def import_wallet!(chain:, address:)
    case chain.to_s
    when "bitcoin"
      import_bitcoin_wallet(address)
    when "ethereum"
      import_ethereum_wallet(address)
    else
      raise ArgumentError, "Unsupported chain"
    end
  end

  def preview_ethereum_wallet(address)
    ethereum_wallet_snapshot(address)
  end

  def import_ethereum_wallet!(address:, selected_token_contracts:)
    import_ethereum_wallet(address, selected_token_contracts: selected_token_contracts)
  end

  private
    def wallet_keys
      onchain_wallet_item.onchain_wallet_accounts
        .select(:chain, :wallet_address)
        .distinct
        .pluck(:chain, :wallet_address)
    end

    def import_bitcoin_wallet(address)
      provider = onchain_wallet_item.mempool_space_provider
      address_payload = provider.get_address(address)
      confirmed_txs = provider.get_address_txs(address)
      mempool_txs = provider.get_mempool_txs(address)

      chain_stats = address_payload.fetch("chain_stats", {})
      mempool_stats = address_payload.fetch("mempool_stats", {})
      sats = chain_stats.fetch("funded_txo_sum", 0).to_d - chain_stats.fetch("spent_txo_sum", 0).to_d
      sats += mempool_stats.fetch("funded_txo_sum", 0).to_d - mempool_stats.fetch("spent_txo_sum", 0).to_d

      quantity = sats / SATS_PER_BTC
      if quantity.zero? && confirmed_txs.blank? && mempool_txs.blank?
        raise Provider::MempoolSpace::InvalidAddressError, "No Bitcoin balance or transactions found for this address."
      end

      account = upsert_wallet_account(
        chain: "bitcoin",
        wallet_address: address,
        asset_kind: "native",
        token_contract: nil,
        symbol: "BTC",
        name: "Bitcoin",
        decimals: 8,
        quantity: quantity,
        raw_payload: address_payload,
        raw_transactions_payload: {
          "transactions" => confirmed_txs.map { |tx| tx.merge("onchain_amount" => bitcoin_transaction_amount(tx, address).to_s) },
          "mempool_transactions" => mempool_txs,
          "fetched_at" => Time.current.iso8601
        }
      )
      ensure_sure_account!(account)

      { "address" => address_payload, "transactions_count" => confirmed_txs.size, "mempool_transactions_count" => mempool_txs.size }
    end

    def import_ethereum_wallet(address, selected_token_contracts: existing_ethereum_token_contracts(address))
      snapshot = ethereum_wallet_snapshot(address)
      balance_wei = snapshot[:balance_wei]
      normal_transactions = snapshot[:normal_transactions]
      token_transfers = snapshot[:token_transfers]
      token_holdings = snapshot[:token_holdings]

      if balance_wei.zero? && normal_transactions.blank? && token_holdings.none? { |holding| holding[:quantity].positive? }
        raise Provider::Etherscan::InvalidAddressError, "No Ethereum balance, token holdings, or transactions found for this address."
      end

      selected_contracts = Array(selected_token_contracts).map { |contract| contract.to_s.downcase }

      eth_quantity = balance_wei / WEI_PER_ETH
      eth_account = upsert_wallet_account(
        chain: "ethereum",
        wallet_address: address,
        asset_kind: "native",
        token_contract: nil,
        symbol: "ETH",
        name: "Ethereum",
        decimals: 18,
        quantity: eth_quantity,
        raw_payload: { "balance_wei" => balance_wei.to_s },
        raw_transactions_payload: {
          "normal_transactions" => normal_transactions.map { |tx| tx.merge("onchain_amount" => ethereum_native_amount(tx, address).to_s) },
          "fetched_at" => Time.current.iso8601
        }
      )
      ensure_sure_account!(eth_account)

      token_holdings.each do |holding|
        next unless holding[:quantity].positive?
        next unless selected_contracts.include?(holding[:contract])

        token_account = upsert_wallet_account(
          chain: "ethereum",
          wallet_address: address,
          asset_kind: "erc20",
          token_contract: holding[:contract],
          symbol: holding[:symbol],
          name: holding[:name],
          decimals: holding[:decimals],
          quantity: holding[:quantity],
          raw_payload: holding.except(:transfers, :current_balance),
          raw_transactions_payload: {
            "token_transfers" => holding[:transfers],
            "fetched_at" => Time.current.iso8601
          }
        )
        ensure_sure_account!(token_account)
      end

      {
        "native_transactions_count" => normal_transactions.size,
        "token_transfers_count" => token_transfers.size,
        "tokens_imported_count" => token_holdings.count { |holding| holding[:quantity].positive? && selected_contracts.include?(holding[:contract]) }
      }
    end

    def ethereum_wallet_snapshot(address)
      provider = onchain_wallet_item.etherscan_provider
      raise Provider::Etherscan::AuthenticationError, "Etherscan API key is required for Ethereum wallets" unless provider

      balance_wei = provider.get_native_balance(address).to_d
      normal_transactions = provider.get_normal_transactions(address)
      token_transfers = provider.get_erc20_transfers(address)
      token_holdings = token_holdings_from_transfers(token_transfers, address)

      if balance_wei.zero? && normal_transactions.blank? && token_holdings.none? { |holding| holding[:quantity].positive? }
        raise Provider::Etherscan::InvalidAddressError, "No Ethereum balance, token holdings, or transactions found for this address."
      end

      {
        balance_wei: balance_wei,
        eth_quantity: balance_wei / WEI_PER_ETH,
        eth_current_balance: estimate_current_balance("ETH", balance_wei / WEI_PER_ETH),
        normal_transactions: normal_transactions,
        token_transfers: token_transfers,
        token_holdings: token_holdings
      }
    end

    def upsert_wallet_account(attrs)
      current_balance = estimate_current_balance(attrs[:symbol], attrs[:quantity])

      onchain_wallet_item.onchain_wallet_accounts
        .find_or_initialize_by(
          chain: attrs[:chain],
          wallet_address: attrs[:wallet_address],
          asset_kind: attrs[:asset_kind],
          token_contract: attrs[:token_contract],
          symbol: attrs[:symbol]
        )
        .tap do |account|
          account.assign_attributes(
            name: attrs[:name],
            decimals: attrs[:decimals],
            quantity: attrs[:quantity],
            currency: onchain_wallet_item.family.currency,
            current_balance: current_balance,
            raw_payload: attrs[:raw_payload],
            raw_transactions_payload: attrs[:raw_transactions_payload],
            institution_metadata: institution_metadata(attrs)
          )
          account.save!
        end
    end

    def ensure_sure_account!(wallet_account)
      return wallet_account.current_account if wallet_account.current_account

      account = Account.create_from_onchain_wallet_account(wallet_account)
      wallet_account.ensure_account_provider!(account)
      account
    end

    def estimate_current_balance(symbol, quantity)
      return 0 if quantity.to_d.zero?

      security = OnchainWalletAccount::SecurityResolver.resolve(symbol, symbol)
      price = security&.current_price
      return 0 unless price

      amount = price.amount.to_d * quantity.to_d
      if price.currency.iso_code == onchain_wallet_item.family.currency
        amount.round(2)
      else
        rate = ExchangeRate.find_or_fetch_rate(from: price.currency.iso_code, to: onchain_wallet_item.family.currency, date: Date.current)
        rate ? (amount * rate.rate.to_d).round(2) : 0
      end
    rescue StandardError => e
      Rails.logger.warn "OnchainWalletItem::Importer - could not price #{symbol}: #{e.message}"
      0
    end

    def token_holdings_from_transfers(transfers, address)
      address_down = address.downcase
      grouped = Hash.new do |hash, contract|
        hash[contract] = { quantity_raw: 0.to_d, transfers: [] }
      end

      transfers.each do |transfer|
        contract = transfer["contractAddress"].to_s.downcase
        next if contract.blank?

        data = grouped[contract]
        decimals = transfer["tokenDecimal"].to_i
        decimals = 18 if decimals.zero?
        data[:symbol] = transfer["tokenSymbol"].to_s.upcase.presence || contract.first(8).upcase
        data[:name] = transfer["tokenName"].presence || data[:symbol]
        data[:decimals] = decimals
        data[:transfers] << transfer.merge("onchain_amount" => token_transfer_amount(transfer, address_down).to_s)
        data[:quantity_raw] += token_transfer_raw_delta(transfer, address_down)
      end

      grouped.map do |contract, data|
        {
          contract: contract,
          symbol: data[:symbol],
          name: data[:name],
          decimals: data[:decimals],
          quantity: data[:quantity_raw] / (10.to_d**data[:decimals]),
          current_balance: estimate_current_balance(data[:symbol], data[:quantity_raw] / (10.to_d**data[:decimals])),
          transfers: data[:transfers]
        }
      end
    end

    def existing_ethereum_token_contracts(address)
      onchain_wallet_item.onchain_wallet_accounts
        .where(chain: "ethereum", wallet_address: address.to_s.downcase, asset_kind: "erc20")
        .pluck(:token_contract)
    end

    def bitcoin_transaction_amount(tx, address)
      incoming = Array(tx["vout"]).sum { |out| out["scriptpubkey_address"].to_s == address ? out["value"].to_d : 0.to_d }
      outgoing = Array(tx["vin"]).sum { |input| input.dig("prevout", "scriptpubkey_address").to_s == address ? input.dig("prevout", "value").to_d : 0.to_d }
      (incoming - outgoing) / SATS_PER_BTC
    end

    def ethereum_native_amount(tx, address)
      value = tx["value"].to_d / WEI_PER_ETH
      tx["from"].to_s.downcase == address.downcase ? -value : value
    end

    def token_transfer_amount(transfer, address_down)
      raw = token_transfer_raw_delta(transfer, address_down)
      decimals = transfer["tokenDecimal"].to_i
      decimals = 18 if decimals.zero?
      raw / (10.to_d**decimals)
    end

    def token_transfer_raw_delta(transfer, address_down)
      value = transfer["value"].to_d
      transfer["from"].to_s.downcase == address_down ? -value : value
    end

    def institution_metadata(attrs)
      {
        "name" => "On-chain Wallets",
        "chain" => attrs[:chain],
        "wallet_address" => attrs[:wallet_address],
        "asset_kind" => attrs[:asset_kind],
        "token_contract" => attrs[:token_contract],
        "symbol" => attrs[:symbol]
      }.compact
    end
end
