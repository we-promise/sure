# frozen_string_literal: true

# Keyless Bittensor (Finney) data provider backed by a public Substrate JSON-RPC
# endpoint. Reads free/liquid TAO balance via System.Account storage. No API key
# required; the endpoint is overridable via ENV for self-hosters.
#
# v1 scope: native free balance only (not staked/α). Transfer history is left
# empty until a keyless indexer path is added — balance sync still powers the
# Crypto account holding + net-worth chart via SecurityResolver (CRYPTO:TAO).
class Provider::BittensorRpc
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  RAO_PER_TAO = 1_000_000_000.to_d
  # SS58 coldkeys for network prefix 42 are typically 48 base58 chars starting with "5".
  ADDRESS_PATTERN = /\A5[1-9A-HJ-NP-Za-km-z]{47}\z/

  def self.rpc_url
    ENV.fetch("BITTENSOR_RPC_URL", "https://entrypoint-finney.opentensor.ai")
  end

  headers "User-Agent" => "Sure On-Chain Wallets", "Content-Type" => "application/json"
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def valid_address?(address)
    address.to_s.match?(ADDRESS_PATTERN) &&
      Provider::BittensorRpc::SubstrateCodec.valid_ss58?(address)
  end

  # @return [String] free balance in rao
  def get_native_balance(address)
    validate_address!(address)
    account_id = Provider::BittensorRpc::SubstrateCodec.ss58_account_id(address)
    raise InvalidAddressError, "Invalid Bittensor address" if account_id.nil?

    storage_key = Provider::BittensorRpc::SubstrateCodec.system_account_storage_key(account_id)
    raw = rpc("state_getStorage", [ "0x#{storage_key.unpack1('H*')}" ])
    Provider::BittensorRpc::SubstrateCodec.decode_account_free_rao(raw).to_s
  end

  # Best-effort placeholder — Substrate transfer history needs an indexer.
  # Returns [] so the importer can still create/sync the native TAO account.
  # @return [Array<Hash>]
  def get_transactions(_address)
    []
  end

  private
    def validate_address!(address)
      raise InvalidAddressError, "Invalid Bittensor address" unless valid_address?(address)
    end

    def rpc(method, params)
      body = { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json
      response = self.class.post(self.class.rpc_url, body: body)
      raise RateLimitError, "Bittensor RPC rate limited" if response.code == 429
      raise ApiError, "Bittensor RPC error (#{response.code})" unless response.code.between?(200, 299)

      payload = JSON.parse(response.body)
      raise ApiError, "Bittensor RPC error: #{payload.dig('error', 'message')}" if payload["error"]

      payload["result"]
    rescue JSON::ParserError => e
      raise ApiError, "Bittensor RPC returned invalid JSON: #{e.message}"
    end
end
