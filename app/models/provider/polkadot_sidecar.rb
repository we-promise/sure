# frozen_string_literal: true

# Keyless Polkadot data source backed by Parity's public Substrate API Sidecar
# for Asset Hub, where DOT balances live since the 2025 migration. Self-hosters
# can point it at their own instance with POLKADOT_SIDECAR_URL.
class Provider::PolkadotSidecar
  include HTTParty
  include Provider::HttpTransport
  extend SslConfigurable

  class Error < StandardError; end
  class InvalidAddressError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  DEFAULT_BASE_URL = "https://polkadot-asset-hub-public-sidecar.parity-chains.parity.io"
  MAX_RETRIES = 3
  RETRY_BASE_DELAY = 0.5

  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  def self.base_url
    ENV["POLKADOT_SIDECAR_URL"].presence || DEFAULT_BASE_URL
  end

  # Free and reserved balances, in planck.
  def balance_info(address)
    attempts = 0

    begin
      attempts += 1
      translate_transport_errors do
        handle_response(self.class.get("#{self.class.base_url}/accounts/#{ERB::Util.url_encode(address)}/balance-info"))
      end
    rescue RateLimitError => e
      raise if attempts > MAX_RETRIES

      Rails.logger.warn("Provider::PolkadotSidecar - rate limited (attempt #{attempts}/#{MAX_RETRIES}): #{e.message}")
      sleep(RETRY_BASE_DELAY * (2**(attempts - 1)))
      retry
    end
  end

  private
    def planck?(value)
      value.is_a?(String) && value.match?(/\A\d+\z/)
    end

    def handle_response(response)
      case response.code
      when 200..299
        body = response.parsed_response
        raise ApiError, "Polkadot Sidecar returned an unexpected body" unless body.is_a?(Hash) && planck?(body["free"]) && planck?(body["reserved"])

        body
      when 400
        raise InvalidAddressError, "Polkadot Sidecar rejected the address"
      when 429
        raise RateLimitError, "Polkadot Sidecar rate limit exceeded"
      else
        raise ApiError, "Polkadot Sidecar API error: #{response.code}"
      end
    end
end
