require "json"
require "uri"

# Physical request boundaries for the wallet snapshot feeder. These readers do
# not assemble a wallet or normalize ledger rows; callers must archive each
# response, persist progress and apply endpoint rate limits between requests.
module Provider::AccountData::OnchainWallet::Readers
  class Error < StandardError; end
  class RateLimited < Error; end
  class AuthenticationError < Error; end
  class InvalidResponse < Error; end

  class Transport
    MAX_BYTES = 32 * 1024 * 1024

    def initialize(http:)
      @http = http
    end

    def get(url, query: {}, invalid_binance_symbol: false)
      request(:get, url, invalid_binance_symbol: invalid_binance_symbol, query: query)
    end

    def post(url, payload:)
      request(:post, url, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" })
    end

    def self.endpoint(value)
      raise ArgumentError unless value.is_a?(String)
      uri = URI.parse(value)
      raise ArgumentError unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
      value.delete_suffix("/")
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid configured explorer endpoint", cause: nil
    end

    private
      def request(method, url, invalid_binance_symbol: false, **options)
        response = @http.public_send(method, self.class.endpoint(url), **options, follow_redirects: false)
        status = response.code.to_i
        raise RateLimited, "On-chain endpoint rate limit exceeded" if status == 429
        raise AuthenticationError, "On-chain endpoint authentication failed" if [ 401, 403 ].include?(status)
        unless status.between?(200, 299) || (invalid_binance_symbol && status == 400)
          raise InvalidResponse, "On-chain endpoint request failed"
        end
        body = response.body
        raise InvalidResponse, "On-chain endpoint returned an invalid response" unless body.is_a?(String) && body.bytesize <= MAX_BYTES
        decoded = JSON.parse(body, decimal_class: BigDecimal)
        return decoded if invalid_binance_symbol && status == 400 && decoded.is_a?(Hash) && decoded["code"] == -1121
        raise InvalidResponse, "On-chain endpoint request failed" unless status.between?(200, 299)
        decoded
      rescue *Provider::HttpTransport::TRANSPORT_ERRORS, JSON::ParserError
        raise Error, "On-chain endpoint is unavailable", cause: nil
      end
  end

  class Bitcoin
    def initialize(base_url: Provider::MempoolSpace.base_url, transport: Transport.new(http: Provider::MempoolSpace))
      @base_url = Transport.endpoint(base_url)
      @transport = transport
    end

    def summary(address:)
      data = @transport.get("#{@base_url}/address/#{validated_address(address)}")
      raise InvalidResponse, "Invalid Bitcoin address summary" unless data.is_a?(Hash) && %w[chain_stats mempool_stats].all? { |key| data[key].is_a?(Hash) }
      data
    end

    def transactions(address:, after: nil)
      unless after.nil? || (after.is_a?(String) && after.match?(/\A[0-9a-fA-F]{64}\z/))
        raise ArgumentError, "Invalid Bitcoin history cursor"
      end
      path = "#{@base_url}/address/#{validated_address(address)}/txs"
      path += "/chain/#{after}" if after
      data = @transport.get(path)
      raise InvalidResponse, "Invalid Bitcoin transaction page" unless data.is_a?(Array) && data.size <= 1000 && data.all? { |row| row.is_a?(Hash) }
      data
    end

    private
      def validated_address(address)
        adapter = Onchain::BitcoinAdapter.new
        raise ArgumentError, "Invalid Bitcoin address" unless adapter.valid_address?(address)
        ERB::Util.url_encode(adapter.canonical_address(address))
      end
  end

  class Evm
    RESOURCES = { summary: nil, token_balances: "token-balances", native_transfers: "transactions", token_transfers: "token-transfers" }.freeze

    def initialize(base_url:, transport: Transport.new(http: Provider::Blockscout))
      @base_url = Transport.endpoint(base_url)
      @transport = transport
    end

    def page(resource:, address:, cursor: nil)
      raise ArgumentError unless RESOURCES.key?(resource) && Onchain::EvmAdapter::ADDRESS_PATTERN.match?(address.to_s)
      path = "#{@base_url}/api/v2/addresses/#{address.downcase}"
      path += "/#{RESOURCES.fetch(resource)}" unless resource == :summary
      raise ArgumentError if resource == :summary && cursor
      query = resource == :token_transfers ? { "type" => "ERC-20" } : {}
      if cursor
        validate_cursor!(cursor)
        raise ArgumentError unless (query.keys & cursor.keys.map(&:to_s)).empty?
        query.merge!(cursor.stringify_keys)
      end
      data = @transport.get(path, query: query)
      if resource == :summary
        raise InvalidResponse, "Invalid EVM address summary" unless data.is_a?(Hash) && data.key?("coin_balance")
        return { data: data, next_cursor: nil }
      end
      if data.is_a?(Array)
        raise InvalidResponse, "Unexpected bare EVM history page" unless resource == :token_balances
        rows, continuation = data, nil
      else
        raise InvalidResponse, "Invalid EVM collection" unless data.is_a?(Hash) && data["items"].is_a?(Array) && data.key?("next_page_params")
        rows, continuation = data.values_at("items", "next_page_params")
        validate_cursor!(continuation) if continuation
        continuation = nil if continuation == {}
      end
      raise InvalidResponse, "Invalid EVM collection rows" unless rows.size <= 10_000 && rows.all? { |row| row.is_a?(Hash) }
      raise InvalidResponse, "Empty EVM page has continuation" if rows.empty? && continuation
      { data: data, next_cursor: continuation }
    end

    private
      def validate_cursor!(cursor)
        raise ArgumentError unless cursor.is_a?(Hash) && cursor.size <= 32
        cursor.each do |key, value|
          raise ArgumentError unless key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
          unless value.nil? || value.is_a?(Integer) || value == true || value == false || (value.is_a?(String) && value.bytesize <= 512)
            raise ArgumentError
          end
        end
      end
  end

  class Etherscan
    def initialize(api_key:, chain_id:, transport: Transport.new(http: Provider::Etherscan))
      raise ArgumentError unless api_key.is_a?(String) && api_key.present? && chain_id.to_s.match?(/\A\d+\z/)
      @api_key, @chain_id, @transport = api_key, chain_id.to_s, transport
    end

    def page(resource:, address:, page:, start_block:, end_block:)
      raise ArgumentError unless %i[native_transfers token_transfers].include?(resource) && Onchain::EvmAdapter::ADDRESS_PATTERN.match?(address.to_s)
      raise ArgumentError unless page.is_a?(Integer) && page.positive? && [ start_block, end_block ].all? { |block| block.is_a?(Integer) && block >= 0 } && start_block <= end_block
      data = @transport.get("#{Provider::Etherscan::BASE_URL}/api", query: {
        apikey: @api_key, chainid: @chain_id, module: "account", action: resource == :native_transfers ? "txlist" : "tokentx",
        address: address.downcase, startblock: start_block, endblock: end_block, page: page, offset: Provider::Etherscan::PAGE_SIZE, sort: "asc"
      })
      raise InvalidResponse, "Invalid Etherscan response" unless data.is_a?(Hash)
      unless data["status"].to_s == "1"
        return { data: data, rows: [], complete: true } if data["message"].to_s.match?(/\ANo transactions found\z/i) && [ [], "No transactions found" ].include?(data["result"])
        error = [ data["result"], data["message"] ].grep(String).join(" ")
        raise RateLimited, "Etherscan rate limit exceeded" if error.match?(/rate limit|max rate|daily limit/i)
        raise AuthenticationError, "Etherscan authentication failed" if error.match?(/invalid api key|missing.*chainid|apikey/i)
        raise InvalidResponse, "Etherscan history request failed"
      end
      rows = data["result"]
      raise InvalidResponse, "Invalid Etherscan history page" unless rows.is_a?(Array) && rows.size <= Provider::Etherscan::PAGE_SIZE && rows.all? { |row| row.is_a?(Hash) }
      { data: data, rows: rows, complete: rows.size < Provider::Etherscan::PAGE_SIZE }
    end

    def inspect
      "#<#{self.class.name}>"
    end
  end

  class Solana
    def initialize(url: Provider::SolanaRpc.url, transport: Transport.new(http: Provider::SolanaRpc))
      @url, @transport = Transport.endpoint(url), transport
    end

    def balance(address:)
      result = rpc("getBalance", [ public_key(address) ])
      raise InvalidResponse, "Invalid Solana balance" unless result.is_a?(Hash) && result["value"].is_a?(Integer) && result["value"] >= 0
      result
    end

    def token_accounts(address:, program_id:)
      raise ArgumentError unless Provider::SolanaRpc::TOKEN_PROGRAM_IDS.include?(program_id)
      result = rpc("getTokenAccountsByOwner", [ public_key(address), { programId: program_id }, { encoding: "jsonParsed" } ])
      unless result.is_a?(Hash) && result["value"].is_a?(Array) && result["value"].all? { |row| row.is_a?(Hash) }
        raise InvalidResponse, "Invalid Solana token accounts"
      end
      result
    end

    def signatures(address:, limit: Onchain::SolanaAdapter::SIGNATURES_PER_SOURCE, before: nil)
      raise ArgumentError unless limit.is_a?(Integer) && limit.between?(1, 1000)
      options = { limit: limit }
      options[:before] = signature(before) if before
      result = rpc("getSignaturesForAddress", [ public_key(address), options ])
      raise InvalidResponse, "Invalid Solana signature page" unless result.is_a?(Array) && result.size <= limit && result.all? { |row| row.is_a?(Hash) }
      result
    end

    def transaction(signature:)
      result = rpc("getTransaction", [ self.signature(signature), { encoding: "jsonParsed", maxSupportedTransactionVersion: 0 } ])
      raise InvalidResponse, "Invalid Solana transaction" unless result.nil? || result.is_a?(Hash)
      result
    end

    private
      def rpc(method, params)
        data = @transport.post(@url, payload: { jsonrpc: "2.0", id: 1, method: method, params: params })
        unless data.is_a?(Hash) && data["jsonrpc"] == "2.0" && data["id"] == 1 && data.key?("result") && data["error"].nil?
          raise InvalidResponse, "Solana RPC request failed"
        end
        data.fetch("result")
      end

      def public_key(value)
        raise ArgumentError unless value.is_a?(String) && Onchain::SolanaAdapter::ADDRESS_PATTERN.match?(value)
        value
      end

      def signature(value)
        raise ArgumentError unless value.is_a?(String) && value.match?(/\A[1-9A-HJ-NP-Za-km-z]{64,88}\z/)
        value
      end
  end
end
