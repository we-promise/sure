# One physical explorer/market request per operation. No model writes, hidden
# pagination, retries or token-list cache. The caller captures even empty results.
class Provider::AccountData::OnchainWallet::Client
  class PublicHttp
    include HTTParty
    extend SslConfigurable
    default_options.merge!({ timeout: 30, max_retries: 0 }.merge(httparty_ssl_options))
  end

  def initialize(configuration:, credentials:, fx_resolver: nil, fx_reader: nil)
    @configuration = configuration
    @credentials = credentials.with_indifferent_access
    @fx_resolver = fx_resolver
    @fx_reader = fx_reader
    @moex_fx_reader = Provider::AccountData::OnchainWallet::MoexFxReader.new(options: configuration.fetch("fx")) if configuration.dig("fx", "provider") == "moex_public"
    @yahoo_fx_reader = Provider::AccountData::OnchainWallet::YahooFxReader.new(options: configuration.fetch("fx")) if configuration.dig("fx", "provider") == "yahoo_finance"
    @transport = Provider::AccountData::OnchainWallet::Readers::Transport.new(http: PublicHttp)
  end

  def read(operation, private_auth: nil, request_clock: nil)
    # This also catches accidental use of the feeder from a factory/collector.
    raise Provider::AccountData::InvalidResponse, "Wallet requests cannot run in a database transaction" if ApplicationRecord.connection.transaction_open?
    # Persisted pages bound retries. A live feeder still respects the slowest
    # shared explorer interval between successive physical requests.
    action, chain, address, arguments = operation.values_at("action", "chain", "address", "arguments")
    # Yahoo owns the final pacing delay and samples its request clock after it,
    # so a cookie cannot expire while waiting behind a second client-level delay.
    unless action == "fx_yahoo"
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep([ 0.4 - (now - @last_request_at), 0 ].max) if @last_request_at
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    definition = @configuration.fetch("chains").fetch(chain) if chain
    case action
    when "bitcoin_summary" then bitcoin.summary(address: address)
    when "bitcoin_history" then bitcoin.transactions(address: address, after: arguments["after"])
    when "evm"
      evm(definition).page(resource: arguments.fetch("resource").to_sym, address: address, cursor: arguments["cursor"]).deep_stringify_keys
    when "etherscan"
      Provider::AccountData::OnchainWallet::Readers::Etherscan.new(api_key: @credentials.fetch(:etherscan_api_key), chain_id: definition.fetch("etherscan_chain_id"))
        .page(resource: arguments.fetch("resource").to_sym, address: address, page: arguments.fetch("page"), start_block: 0, end_block: 999_999_999).deep_stringify_keys
    when "solana_balance" then solana.balance(address: address)
    when "solana_tokens" then solana.token_accounts(address: address, program_id: arguments.fetch("program_id"))
    when "solana_signatures" then solana.signatures(address: address, limit: Onchain::SolanaAdapter::SIGNATURES_PER_SOURCE)
    when "solana_transaction" then solana.transaction(signature: arguments.fetch("signature"))
    when "token_metadata"
      rows = @transport.get(@configuration.fetch("token_list_url"), query: { query: arguments.fetch("mints").join(",") })
      raise ArgumentError unless rows.is_a?(Array) && rows.size <= 10_000 && rows.all? { |row| row.is_a?(Hash) }
      rows
    when "price" then price(arguments)
    when "fx"
      @fx_resolver&.call(from: arguments.fetch("from"), to: arguments.fetch("to"), date: Date.iso8601(arguments.fetch("date")))&.transform_values do |value|
        value.is_a?(BigDecimal) ? value.to_s("F") : value
      end&.stringify_keys
    when "fx_remote"
      raise ArgumentError unless @fx_reader
      @fx_reader.read(from: arguments.fetch("from"), to: arguments.fetch("to"), date: Date.iso8601(arguments.fetch("date")))
    when "fx_moex_history"
      raise ArgumentError unless @moex_fx_reader
      @moex_fx_reader.read(from: arguments.fetch("from"), to: arguments.fetch("to"), date: Date.iso8601(arguments.fetch("date")), start: arguments.fetch("start"))
    when "fx_yahoo"
      raise ArgumentError unless @yahoo_fx_reader && private_auth.is_a?(Hash) && request_clock.respond_to?(:call)
      @yahoo_fx_reader.read(action: arguments.fetch("step"), from: arguments.fetch("from"), to: arguments.fetch("to"),
        date: Date.iso8601(arguments.fetch("date")), auth_generation: arguments.fetch("auth_generation"), direction: arguments["direction"],
        auth: private_auth, request_clock: request_clock)
    else raise ArgumentError
    end
  rescue ArgumentError, TypeError, KeyError
    raise Provider::AccountData::InvalidResponse, "Invalid wallet capture operation", cause: nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def bitcoin
      @bitcoin ||= Provider::AccountData::OnchainWallet::Readers::Bitcoin.new(base_url: @configuration.fetch("bitcoin_url"))
    end

    def evm(definition)
      Provider::AccountData::OnchainWallet::Readers::Evm.new(base_url: definition.fetch("explorer_url"))
    end

    def solana
      @solana ||= Provider::AccountData::OnchainWallet::Readers::Solana.new(url: @configuration.fetch("solana_url"))
    end

    def price(arguments)
      return { "policy" => "disabled", "rows" => [] } unless @configuration.fetch("price_enabled")
      parsed = Provider::BinancePublic.parse_ticker(arguments.fetch("ticker")) || raise(ArgumentError)
      if parsed[:stablecoin]
        return { "policy" => "binance_public_stablecoin_usd_one/v1", "currency" => "USD", "price" => "1", "date" => arguments.fetch("date") }
      end
      date = Date.iso8601(arguments.fetch("date"))
      milliseconds = Time.utc(date.year, date.month, date.day).to_i * 1000
      rows = @transport.get("#{Provider::AccountData::OnchainWallet::Readers::Transport.endpoint(@configuration.fetch('price_url'))}/api/v3/klines",
        query: { symbol: parsed.fetch(:binance_pair), interval: "1d", startTime: milliseconds, endTime: milliseconds + 86_400_000 - 1, limit: 1 }, invalid_binance_symbol: true)
      return { "policy" => "binance_public_invalid_symbol/v1", "rows" => [], "code" => -1121 } if rows.is_a?(Hash) && rows["code"] == -1121
      raise ArgumentError unless rows.is_a?(Array) && rows.size <= 1 && rows.all? { |row| row.is_a?(Array) && row.size >= 7 }
      { "policy" => "binance_public_daily_close/v1", "currency" => parsed.fetch(:display_currency), "rows" => rows }
    end
end
