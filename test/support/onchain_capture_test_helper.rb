module OnchainCaptureTestHelper
  Wallet = Provider::AccountData::OnchainWallet
  BITCOIN_ADDRESS = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT".freeze
  EVM_ADDRESS = "0x#{'a' * 40}".freeze
  SOLANA_ADDRESS = ("A" * 44).freeze

  def wallet_configuration(**changes)
    Wallet::Configuration.build.merge("price_enabled" => false, "history_pages" => 2, "history_transactions" => 2, "asset_tokens" => 2)
      .merge(changes.stringify_keys)
  end

  def wallet_source(chain: Onchain::Chains::BITCOIN, kind: "native", contract: nil, symbol: nil, currency: "USD", id: SecureRandom.uuid)
    definition = Onchain::Chains.find!(chain)
    address = { nil => BITCOIN_ADDRESS, "erc20" => EVM_ADDRESS, "spl" => SOLANA_ADDRESS }.fetch(definition.token_kind)
    descriptor = { "version" => 1, "chain" => chain, "asset_kind" => kind, "wallet_address" => address,
      "contract_address" => contract, "symbol" => symbol || definition.native.symbol, "name" => symbol || definition.native.name,
      "decimals" => kind == "native" ? definition.native.decimals : 6, "ingestion_namespace" => "onchain_#{id}" }
    { descriptor: descriptor, external: { id: id, external_id: Wallet::SourceDescriptor.external_id(descriptor), identity_namespace: "default",
      name: "Selected asset", currency: currency, sensitive_details: { "source_descriptor" => descriptor } }.with_indifferent_access }
  end

  def capture_scope(observed_at)
    { "family_id" => "family", "connection_id" => "connection", "sync_id" => "sync", "observed_at" => observed_at.getutc.iso8601(9) }
  end

  def wallet_assembly(sources:, configuration: wallet_configuration, observed_at: Time.current, keyed_history: false)
    Wallet::Assembly.new(sources: sources, configuration: configuration, observed_at: observed_at, timezone: "UTC",
      sync_start_date: nil, keyed_history: keyed_history)
  end

  def finish_assembly(assembly, &response)
    200.times do
      operation = assembly.next_operation
      return assembly unless operation
      value = response.call(operation)
      assembly.accept!(operation: operation, response: value, fetched_at: Time.current.getutc.iso8601(9))
    end
    flunk "Fixture capture did not terminate"
  end

  def bitcoin_summary(quantity: "200000000")
    { "chain_stats" => { "funded_txo_sum" => quantity.to_i, "spent_txo_sum" => 0 },
      "mempool_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 } }
  end

  def disabled_quote
    { "policy" => "disabled", "rows" => [] }
  end

  def daily_quote(date:, amount: "50000", currency: "USD")
    day = Date.iso8601(date)
    milliseconds = Time.utc(day.year, day.month, day.day).to_i * 1000
    { "policy" => "binance_public_daily_close/v1", "currency" => currency, "rows" => [ [ milliseconds, "0", "0", "0", amount, "0", milliseconds + 86_399_999 ] ] }
  end
end
