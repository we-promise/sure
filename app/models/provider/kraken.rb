require "base64"
require "cgi"
require "digest"
require "openssl"
require "uri"

class Provider::Kraken
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  API_BASE_URL = "https://api.kraken.com".freeze
  PUBLIC_PREFIX = "/0/public".freeze
  PRIVATE_PREFIX = "/0/private".freeze
  PAGE_SIZE = 50
  ASSET_CODE_OVERRIDES = {
    "XBT" => "BTC"
  }.freeze
  FIAT_ASSETS = %w[AUD CAD CHF DAI EUR GBP JPY USD USDC USDT].freeze

  base_uri API_BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
  end

  def get_balances
    post_private("#{PRIVATE_PREFIX}/Balance").dig("result") || {}
  end

  def get_ledgers(start: nil, end_time: nil, type: nil)
    paginated_private_hash(
      "#{PRIVATE_PREFIX}/Ledgers",
      result_key: "ledger",
      base_payload: compact_payload(start: start, end: end_time, type: type)
    )
  end

  def get_trades_history(start: nil, end_time: nil, type: nil)
    paginated_private_hash(
      "#{PRIVATE_PREFIX}/TradesHistory",
      result_key: "trades",
      base_payload: compact_payload(start: start, end: end_time, type: type)
    )
  end

  def get_asset_info
    get_public("#{PUBLIC_PREFIX}/Assets").dig("result") || {}
  end

  def get_asset_pairs
    get_public("#{PUBLIC_PREFIX}/AssetPairs").dig("result") || {}
  end

  def get_ticker(pair)
    result = get_public("#{PUBLIC_PREFIX}/Ticker", pair: pair).dig("result") || {}
    result.values.first
  end

  def get_spot_price(asset:, quote_currency:)
    return 1.to_d if normalize_asset_code(asset) == normalize_asset_code(quote_currency)

    pair = pair_metadata(base_asset: asset, quote_asset: quote_currency)
    return nil unless pair

    ticker = get_ticker(pair[:key])
    price = ticker&.dig("c", 0) || ticker&.dig("p", 0)
    price.present? ? price.to_d : nil
  rescue => e
    Rails.logger.warn("Kraken: failed to fetch spot price for #{asset}/#{quote_currency}: #{e.class} - #{e.message}")
    nil
  end

  def normalize_asset_code(asset_code)
    raw_code = asset_code.to_s.upcase
    base_code = raw_code.split(".").first
    info = asset_info_by_code[base_code] || asset_info_by_altname[base_code]

    canonical = info&.dig(:altname).to_s.upcase.presence
    canonical ||= if base_code.start_with?("X", "Z") && base_code.length > 3
      base_code[1..].to_s.upcase
    else
      base_code
    end

    ASSET_CODE_OVERRIDES.fetch(canonical, canonical)
  end

  def fiat_asset?(asset_code)
    normalize_asset_code(asset_code).in?(FIAT_ASSETS)
  end

  def asset_display_name(asset_code)
    raw_code = asset_code.to_s.upcase.split(".").first
    info = asset_info_by_code[raw_code] || asset_info_by_altname[raw_code]
    info&.dig(:altname).presence || normalize_asset_code(asset_code)
  end

  def asset_full_name(asset_code)
    raw_code = asset_code.to_s.upcase.split(".").first
    info = asset_info_by_code[raw_code] || asset_info_by_altname[raw_code]
    info&.dig(:aclass) == "currency" ? asset_display_name(asset_code) : asset_display_name(asset_code)
  end

  def pair_metadata(base_asset:, quote_asset:)
    base = normalize_asset_code(base_asset)
    preferred_quotes = preferred_quote_candidates(quote_asset)

    normalized_asset_pairs.find do |pair|
      pair[:base] == base && preferred_quotes.include?(pair[:quote])
    end
  end

  def pair_for_code(pair_code)
    code = pair_code.to_s.upcase

    normalized_asset_pairs.find do |pair|
      candidates = [
        pair[:key].to_s.upcase,
        pair[:altname].to_s.upcase,
        pair[:wsname].to_s.upcase,
        pair[:wsname].to_s.delete("/-").upcase
      ].reject(&:blank?)

      normalized_code = code.delete("/-")
      candidates.include?(code) || candidates.include?(normalized_code)
    end
  end

  private

    def asset_info_by_code
      @asset_info_by_code ||= begin
        get_asset_info.each_with_object({}) do |(code, data), memo|
          memo[code.to_s.upcase] = data.with_indifferent_access
        end
      end
    end

    def asset_info_by_altname
      @asset_info_by_altname ||= asset_info_by_code.each_with_object({}) do |(_code, data), memo|
        altname = data[:altname].to_s.upcase
        memo[altname] = data if altname.present?
      end
    end

    def normalized_asset_pairs
      @normalized_asset_pairs ||= get_asset_pairs.each_with_object([]) do |(key, pair_data), memo|
        pair = pair_data.with_indifferent_access
        next if pair[:wsname].to_s.downcase.include?(".d")
        next unless pair[:status].blank? || pair[:status] == "online"

        base_asset = pair[:base].presence || pair[:wsname].to_s.split("/").first
        quote_asset = pair[:quote].presence || pair[:wsname].to_s.split("/").last
        next if base_asset.blank? || quote_asset.blank?

        memo << {
          key: key,
          altname: pair[:altname],
          wsname: pair[:wsname],
          base: normalize_asset_code(base_asset),
          quote: normalize_asset_code(quote_asset)
        }
      end
    end

    def preferred_quote_candidates(requested_quote)
      requested = normalize_asset_code(requested_quote)
      ([ requested ] + fallback_quotes_for(requested)).uniq
    end

    def fallback_quotes_for(requested_quote)
      case requested_quote
      when "USD"
        %w[USDT USDC EUR]
      when "EUR"
        %w[USD USDT]
      else
        %w[USD EUR USDT]
      end
    end

    def compact_payload(payload)
      payload.compact.transform_values do |value|
        value.is_a?(Time) ? value.to_i : value
      end
    end

    def nonce
      (Time.now.to_f * 1000).to_i.to_s
    end

    def get_public(path, query = {})
      response = self.class.get(path, query: query)
      handle_response(response)
    end

    def post_private(path, payload = {})
      body = URI.encode_www_form(payload.merge(nonce: nonce).transform_values(&:to_s))

      response = self.class.post(
        path,
        body: body,
        headers: auth_headers(path, body)
      )

      handle_response(response)
    end

    def paginated_private_hash(path, result_key:, base_payload:)
      results = {}
      offset = 0
      total_count = nil

      loop do
        response = post_private(path, base_payload.merge(ofs: offset))
        result = response["result"] || {}
        page = result[result_key] || {}

        results.merge!(page)
        total_count ||= result["count"].to_i

        break if page.empty?
        break if total_count.positive? && results.size >= total_count

        offset += page.size
        break if page.size < PAGE_SIZE
      end

      results
    end

    def auth_headers(path, encoded_body)
      {
        "API-Key" => api_key,
        "API-Sign" => generate_signature(path, encoded_body),
        "Content-Type" => "application/x-www-form-urlencoded; charset=utf-8",
        "Accept" => "application/json"
      }
    end

    def generate_signature(path, encoded_body)
      nonce_value = CGI.parse(encoded_body)["nonce"]&.first.to_s
      sha = Digest::SHA256.digest("#{nonce_value}#{encoded_body}")
      message = path + sha
      secret = Base64.decode64(api_secret)
      Base64.strict_encode64(OpenSSL::HMAC.digest("sha512", secret, message))
    end

    def handle_response(response)
      parsed = response.parsed_response
      parsed = JSON.parse(response.body) if parsed.is_a?(String)

      errors = Array(parsed["error"]).compact.reject(&:blank?)
      if response.code.to_i >= 400 && errors.empty?
        raise ApiError, "Kraken API error: HTTP #{response.code}"
      end

      return parsed if errors.empty?

      message = errors.join(", ")

      if authentication_error?(message)
        raise AuthenticationError, message
      elsif rate_limit_error?(response.code, message)
        raise RateLimitError, message.presence || "Kraken rate limit exceeded"
      else
        raise ApiError, message.presence || "Kraken API error"
      end
    rescue JSON::ParserError => e
      raise ApiError, "Kraken API returned invalid JSON: #{e.message}"
    end

    def authentication_error?(message)
      message.match?(/invalid key|invalid signature|permission denied|invalid nonce|two-factor/i)
    end

    def rate_limit_error?(status_code, message)
      status_code.to_i == 429 || message.match?(/rate limit/i)
    end
end
