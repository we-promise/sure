# frozen_string_literal: true

class OnchainWalletItem::Importer
  SATS_PER_BTC = 100_000_000.to_d
  WEI_PER_ETH = 1_000_000_000_000_000_000.to_d
  LAMPORTS_PER_SOL = 1_000_000_000.to_d

  # Native coin metadata per EVM chain. All EVM natives use 18 decimals, so the
  # WEI_PER_ETH divisor applies across chains. Pricing flows through Sure's
  # securities provider (e.g. Binance Public) via the symbol, same as ETH.
  EVM_NATIVE = {
    "ethereum" => { symbol: "ETH",  name: "Ethereum" },
    "polygon"  => { symbol: "POL",  name: "Polygon" },
    "arbitrum" => { symbol: "ETH",  name: "Ethereum (Arbitrum)" },
    "optimism" => { symbol: "ETH",  name: "Ethereum (Optimism)" },
    "base"     => { symbol: "ETH",  name: "Ethereum (Base)" },
    "gnosis"   => { symbol: "XDAI", name: "xDai" }
  }.freeze
  EVM_CHAINS = EVM_NATIVE.keys.freeze

  # Bridged / wrapped stablecoin symbols normalized to their canonical asset so
  # Sure's price provider recognizes them (e.g. USDT0, a LayerZero-bridged USDT,
  # prices the same as USDT).
  STABLECOIN_ALIASES = {
    "USDT0"  => "USDT",
    "USDT.E" => "USDT",
    "USDC.E" => "USDC",
    "USDBC"  => "USDC"
  }.freeze

  attr_reader :onchain_wallet_item

  def initialize(onchain_wallet_item)
    @onchain_wallet_item = onchain_wallet_item
    # Ids of accounts whose on-chain state actually changed this run, so the
    # syncer can skip re-processing/re-materializing unchanged accounts.
    @changed_account_ids = []
  end

  attr_reader :changed_account_ids

  def import
    imported = 0
    snapshots = {}

    wallet_keys.each do |chain, address|
      if chain == "bitcoin"
        snapshots[address] = import_bitcoin_wallet(address)
      elsif EVM_CHAINS.include?(chain)
        snapshots[address] = import_evm_wallet(chain, address)
      elsif chain == "solana"
        snapshots[address] = import_solana_wallet(address)
      end
      imported += 1
    end

    onchain_wallet_item.upsert_onchain_snapshot!({
      "wallets" => snapshots,
      "imported_at" => Time.current.iso8601
    })

    {
      success: true,
      wallets_imported: imported,
      accounts_imported: onchain_wallet_item.onchain_wallet_accounts.count,
      changed_account_ids: changed_account_ids.uniq
    }
  end

  def import_wallet!(chain:, address:)
    chain = chain.to_s
    if chain == "bitcoin"
      import_bitcoin_wallet(address)
    elsif EVM_CHAINS.include?(chain)
      import_evm_wallet(chain, address)
    elsif chain == "solana"
      import_solana_wallet(address)
    else
      raise ArgumentError, "Unsupported chain"
    end
  end

  # Preview tokens before import (EVM chains only). Defaults to Ethereum for
  # backwards compatibility with existing callers.
  def preview_evm_wallet(chain, address)
    evm_wallet_snapshot(chain, address)
  end

  def preview_ethereum_wallet(address)
    preview_evm_wallet("ethereum", address)
  end

  def import_evm_wallet!(chain:, address:, selected_token_contracts:)
    import_evm_wallet(chain, address, selected_token_contracts: selected_token_contracts)
  end

  def import_ethereum_wallet!(address:, selected_token_contracts:)
    import_evm_wallet!(chain: "ethereum", address: address, selected_token_contracts: selected_token_contracts)
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

    def import_evm_wallet(chain, address, selected_token_contracts: nil)
      selected_token_contracts ||= existing_evm_token_contracts(chain, address)
      native = EVM_NATIVE.fetch(chain)
      snapshot = evm_wallet_snapshot(chain, address)
      balance_wei = snapshot[:balance_wei]
      normal_transactions = snapshot[:normal_transactions]
      token_transfers = snapshot[:token_transfers]
      token_holdings = snapshot[:token_holdings]

      selected_contracts = Array(selected_token_contracts).map { |contract| contract.to_s.downcase }

      native_quantity = balance_wei / WEI_PER_ETH
      native_account = upsert_wallet_account(
        chain: chain,
        wallet_address: address,
        asset_kind: "native",
        token_contract: nil,
        symbol: native[:symbol],
        name: native[:name],
        decimals: 18,
        quantity: native_quantity,
        raw_payload: { "balance_wei" => balance_wei.to_s },
        raw_transactions_payload: {
          "normal_transactions" => normal_transactions.map { |tx| tx.merge("onchain_amount" => ethereum_native_amount(tx, address).to_s) },
          "fetched_at" => Time.current.iso8601
        }
      )
      ensure_sure_account!(native_account)

      token_holdings.each do |holding|
        next unless selected_contracts.include?(holding[:contract])

        token_account = upsert_wallet_account(
          chain: chain,
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

    # Reads balances + transactions from a keyless Blockscout instance for the
    # given EVM chain.
    def evm_wallet_snapshot(chain, address)
      native = EVM_NATIVE.fetch(chain)
      provider = onchain_wallet_item.evm_provider(chain)

      balance_wei = provider.get_native_balance(address).to_d
      normal_transactions = provider.get_normal_transactions(address)
      token_transfers = provider.get_erc20_transfers(address)
      token_holdings = token_holdings_from_transfers(token_transfers, address)

      if balance_wei.zero? && normal_transactions.blank? && token_holdings.none? { |holding| holding[:quantity].positive? }
        raise evm_invalid_address_error_class(provider), "No #{native[:name]} balance, token holdings, or transactions found for this address."
      end

      {
        balance_wei: balance_wei,
        native_quantity: balance_wei / WEI_PER_ETH,
        native_current_balance: estimate_current_balance(native[:symbol], balance_wei / WEI_PER_ETH),
        normal_transactions: normal_transactions,
        token_transfers: token_transfers,
        token_holdings: token_holdings
      }
    end

    def upsert_wallet_account(attrs)
      current_balance = estimate_current_balance(attrs[:symbol], attrs[:quantity])
      signature = content_signature(attrs)

      account = onchain_wallet_item.onchain_wallet_accounts.find_or_initialize_by(
        chain: attrs[:chain],
        wallet_address: attrs[:wallet_address],
        asset_kind: attrs[:asset_kind],
        token_contract: attrs[:token_contract],
        symbol: attrs[:symbol]
      )

      # Idempotent sync: when the on-chain state (quantity + transaction set) is
      # unchanged, only refresh the price-derived balance and skip re-writing the
      # heavy on-chain fields — and crucially, don't mark the account changed, so
      # the syncer won't re-process/re-materialize it (no value-graph churn).
      if account.persisted? && account.content_hash == signature
        account.update_column(:current_balance, current_balance) if account.current_balance != current_balance
        return account
      end

      account.assign_attributes(
        name: attrs[:name],
        decimals: attrs[:decimals],
        quantity: attrs[:quantity],
        currency: onchain_wallet_item.family.currency,
        current_balance: current_balance,
        raw_payload: attrs[:raw_payload],
        raw_transactions_payload: attrs[:raw_transactions_payload],
        institution_metadata: institution_metadata(attrs),
        content_hash: signature
      )
      account.save!
      @changed_account_ids << account.id
      account
    end

    # Signature of the on-chain state we care about for change detection:
    # the token quantity plus the set of transaction ids. Price is intentionally
    # excluded — value tracks price via the daily security-price job, not this
    # 30-minute on-chain sync.
    def content_signature(attrs)
      tx_ids = transaction_ids_from(attrs[:raw_transactions_payload])
      payload = [ attrs[:quantity].to_s, tx_ids.sort ].to_json
      Digest::SHA256.hexdigest(payload)
    end

    def transaction_ids_from(raw_transactions_payload)
      payload = raw_transactions_payload || {}
      Array(payload["transactions"] || payload["normal_transactions"] || payload["token_transfers"])
        .filter_map { |tx| tx["hash"] || tx["txid"] }
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
        data[:symbol] = canonical_symbol(transfer["tokenSymbol"].to_s.upcase.presence || contract.first(8).upcase)
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

    def evm_invalid_address_error_class(provider)
      if provider.is_a?(Provider::Etherscan)
        Provider::Etherscan::InvalidAddressError
      else
        Provider::Blockscout::InvalidAddressError
      end
    end

    # Imports native SOL + SPL token balances (and best-effort tx history) from
    # a keyless Solana RPC. Unlike EVM, balances are read directly.
    def import_solana_wallet(address)
      provider = onchain_wallet_item.solana_provider
      lamports = provider.get_native_balance(address).to_d
      sol_quantity = lamports / LAMPORTS_PER_SOL
      token_balances = provider.get_token_balances(address)
      transactions = provider.get_transactions(address)

      if sol_quantity.zero? && token_balances.none? { |t| t[:ui_amount].positive? } && transactions.blank?
        raise Provider::SolanaRpc::InvalidAddressError, "No Solana balance or transactions found for this address."
      end

      native_txs = transactions.select { |tx| tx["symbol"] == "SOL" }
      sol_account = upsert_wallet_account(
        chain: "solana",
        wallet_address: address,
        asset_kind: "native",
        token_contract: nil,
        symbol: "SOL",
        name: "Solana",
        decimals: 9,
        quantity: sol_quantity,
        raw_payload: { "lamports" => lamports.to_s },
        raw_transactions_payload: { "transactions" => native_txs, "fetched_at" => Time.current.iso8601 }
      )
      ensure_sure_account!(sol_account)

      token_balances.each do |token|
        next unless token[:ui_amount].positive?

        mint_txs = transactions.select { |tx| tx["mint"] == token[:mint] }
        token_account = upsert_wallet_account(
          chain: "solana",
          wallet_address: address,
          asset_kind: "spl",
          token_contract: token[:mint],
          symbol: canonical_symbol(token[:symbol]),
          name: token[:name],
          decimals: token[:decimals],
          quantity: token[:ui_amount],
          raw_payload: { "mint" => token[:mint] },
          raw_transactions_payload: { "transactions" => mint_txs, "fetched_at" => Time.current.iso8601 }
        )
        ensure_sure_account!(token_account)
      end

      {
        "sol_quantity" => sol_quantity.to_s,
        "tokens_imported_count" => token_balances.count { |t| t[:ui_amount].positive? },
        "transactions_count" => transactions.size
      }
    end

    def existing_evm_token_contracts(chain, address)
      onchain_wallet_item.onchain_wallet_accounts
        .where(chain: chain, wallet_address: address.to_s.downcase, asset_kind: "erc20")
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

    def canonical_symbol(symbol)
      up = symbol.to_s.upcase
      STABLECOIN_ALIASES.fetch(up, up)
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
