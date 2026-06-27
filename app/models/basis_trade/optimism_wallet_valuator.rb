require "json"
require "net/http"

class BasisTrade::OptimismWalletValuator
  RPC_URL = "https://mainnet.optimism.io".freeze
  PRICE_API_URL = "https://coins.llama.fi/prices/current".freeze
  NATIVE_WETH_ADDRESS = "0x4200000000000000000000000000000000000006".freeze
  ERC20_BALANCE_OF = "70a08231".freeze
  ERC20_DECIMALS = "313ce567".freeze
  ERC20_SYMBOL = "95d89b41".freeze

  def value(address:, token_addresses: [])
    normalized_tokens = token_addresses.map(&:downcase).uniq

    native_balance = balance_for_native(address)
    erc20_rows = normalized_tokens.map { |token| token_row(address, token) }
    priced_rows = price_rows([ native_token_row(native_balance), *erc20_rows ])

    {
      total_value: priced_rows.sum { |row| row[:value_usd] },
      tokens: priced_rows
    }
  end

  private

    def native_token_row(balance)
      {
        address: NATIVE_WETH_ADDRESS,
        symbol: "ETH",
        decimals: 18,
        balance: balance,
        token_type: :native
      }
    end

    def token_row(owner_address, token_address)
      {
        address: token_address,
        symbol: token_symbol(token_address),
        decimals: token_decimals(token_address),
        balance: token_balance(owner_address, token_address),
        token_type: :erc20
      }
    end

    def price_rows(rows)
      prices = fetch_prices(rows.map { |row| "optimism:#{row[:address]}" })

      rows.map do |row|
        price = BigDecimal(prices.fetch("optimism:#{row[:address]}", 0).to_s)
        value = row[:balance] * price
        row.merge(price_usd: price, value_usd: value)
      end
    end

    def fetch_prices(keys)
      uri = URI("#{PRICE_API_URL}/#{keys.join(',')}")
      response = Net::HTTP.get_response(uri)
      raise "DefiLlama price request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      parsed.fetch("coins", {}).transform_values { |value| value["price"] }
    end

    def balance_for_native(address)
      wei_hex = rpc_call("eth_getBalance", [ address, "latest" ])
      decode_decimal(wei_hex, 18)
    end

    def token_balance(owner_address, token_address)
      data = "0x#{ERC20_BALANCE_OF}#{owner_address.delete_prefix('0x').rjust(64, '0')}"
      decode_decimal(rpc_call("eth_call", [ { to: token_address, data: data }, "latest" ]), token_decimals(token_address))
    end

    def token_decimals(token_address)
      @token_decimals ||= {}
      @token_decimals[token_address] ||= rpc_call("eth_call", [ { to: token_address, data: "0x#{ERC20_DECIMALS}" }, "latest" ]).to_i(16)
    end

    def token_symbol(token_address)
      @token_symbols ||= {}
      @token_symbols[token_address] ||= begin
        raw = rpc_call("eth_call", [ { to: token_address, data: "0x#{ERC20_SYMBOL}" }, "latest" ])
        decode_symbol(raw)
      end
    end

    def rpc_call(method, params)
      uri = URI(RPC_URL)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      raise "Optimism RPC request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      raise "Optimism RPC error: #{parsed['error']}" if parsed["error"].present?

      parsed.fetch("result")
    end

    def decode_decimal(hex_value, decimals)
      BigDecimal(hex_value.to_i(16).to_s) / (10 ** decimals)
    end

    def decode_symbol(hex_value)
      payload = hex_value.delete_prefix("0x")
      if payload.length >= 128
        offset = payload[0, 64].to_i(16) * 2
        length = payload[offset, 64].to_i(16)
        bytes = [ payload[offset + 64, length * 2] ].pack("H*")
        value = bytes.force_encoding("UTF-8").scrub.strip
        return value if value.present?
      end

      [ payload ].pack("H*").delete("\u0000").strip.presence || "TOKEN"
    rescue StandardError
      "TOKEN"
    end
end
