require "json"

# A single request, with the selected endpoint and credentials captured at the
# factory boundary. Never call the legacy provider registry, retry middleware or
# ExchangeRate.find_or_fetch_rate from here. Successful and terminal unavailable
# responses are replayable values; transient failures leave the operation pending.
class Provider::AccountData::OnchainWallet::FxReader
  MAX_BYTES = 1024 * 1024
  SUPPORTED = %w[twelve_data frankfurter].freeze
  ENVELOPE_KEYS = %w[http_status provider request response status version].freeze
  STATUSES = %w[response unsupported_provider credential_unavailable authentication_failed request_failed invalid_response].freeze

  class Http
    include HTTParty
    extend SslConfigurable
    default_options.merge!({ timeout: 20, max_retries: 0 }.merge(httparty_ssl_options))
  end

  def initialize(options:, credentials:, http: Http)
    @options = options.deep_stringify_keys
    @credentials = credentials.deep_stringify_keys
    @http = http
    unless @options["version"] == 1 && @options["provider"] == @credentials["provider"] &&
        @options["credential_fingerprint"] == Provider::AccountData::OnchainWallet::FxConfiguration.fingerprint(@credentials)
      raise Provider::AccountData::StaleWriter, "Wallet FX credentials differ from captured configuration"
    end
    if SUPPORTED.include?(@options["provider"])
      @endpoint = Provider::AccountData::OnchainWallet::Readers::Transport.endpoint(@options.fetch("endpoint"))
    end
    @interval = Float(@options.fetch("min_interval_seconds"))
    raise ArgumentError unless @interval.finite? && @interval.between?(0, 60)
  end

  def read(from:, to:, date:)
    request = self.class.request(from: from, to: to, date: date)
    if ApplicationRecord.connection.transaction_open?
      raise Provider::AccountData::InvalidResponse, "Wallet FX requests cannot run in a database transaction"
    end
    return envelope(request, "unsupported_provider") unless SUPPORTED.include?(provider)
    return envelope(request, "credential_unavailable") if provider == "twelve_data" && @credentials["api_key"].blank?
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep([ @interval - (now - @last_request_at), 0 ].max) if @last_request_at
    @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = if provider == "twelve_data"
      @http.get("#{@endpoint}/exchange_rate", query: { symbol: "#{from}/#{to}", date: date.iso8601, timezone: "UTC" },
        headers: { "Authorization" => "apikey #{@credentials.fetch('api_key')}" }, follow_redirects: false)
    else
      @http.get("#{@endpoint}/rate/#{from}/#{to}", query: { date: date.iso8601 }, follow_redirects: false)
    end
    code = response.code.to_i
    reject_transient!(code)
    return envelope(request, "authentication_failed", code: code) if [ 401, 403 ].include?(code)
    return envelope(request, "request_failed", code: code) unless code.between?(200, 299)
    body = response.body
    return envelope(request, "invalid_response", code: code) unless body.is_a?(String) && body.bytesize <= MAX_BYTES
    data = JSON.parse(body, decimal_class: BigDecimal)
    return envelope(request, "invalid_response", code: code) unless data.is_a?(Hash)
    # Never retain request headers, credentials or provider error messages. The
    # exact numeric/date/identity fields used for normalization remain captured.
    keys = provider == "twelve_data" ? %w[symbol rate timestamp date code status] : %w[base quote rate date]
    selected = data.slice(*keys)
    unless selected.values.all? { |value| value.nil? || value.is_a?(Integer) || value.is_a?(BigDecimal) || (value.is_a?(String) && value.bytesize <= 128) }
      return envelope(request, "invalid_response", code: code)
    end
    status = if provider == "twelve_data" && data["code"].present?
      reject_transient!(data["code"])
      [ "401", "403" ].include?(data["code"].to_s) ? "authentication_failed" : "request_failed"
    else
      "response"
    end
    envelope(request, status, code: code, response: selected)
  rescue JSON::ParserError
    envelope(request, "invalid_response", code: code)
  rescue *Provider::HttpTransport::TRANSPORT_ERRORS
    # A transport failure has no response to archive and must be retried by the
    # enclosing execution, not converted into a permanent unavailable quote.
    raise Provider::AccountData::OnchainWallet::Readers::Error, "Wallet FX endpoint is unavailable", cause: nil
  end

  def self.rate(capture, from:, to:, date:, provider:)
    expected = request(from: from, to: to, date: date)
    unless capture.is_a?(Hash) && capture.keys.sort == ENVELOPE_KEYS && capture["version"] == 1 &&
        capture["provider"] == provider && capture["request"] == expected && STATUSES.include?(capture["status"]) && capture["response"].is_a?(Hash) &&
        (capture["http_status"].nil? || (capture["http_status"].is_a?(Integer) && capture["http_status"].between?(100, 599)))
      raise ArgumentError
    end
    return unless capture["status"] == "response"
    return unless SUPPORTED.include?(provider) && capture["http_status"].is_a?(Integer) && capture["http_status"].between?(200, 299)
    data = capture.fetch("response")
    if provider == "twelve_data"
      return unless (data.keys - %w[symbol rate timestamp date code status]).empty? && data["symbol"] == "#{from}/#{to}" &&
        data["code"].blank? && data["status"] != "error"
      actual = twelve_data_date(data)
    else
      return unless (data.keys - %w[base quote rate date]).empty? && data["base"] == from && data["quote"] == to
      actual = exact_date(data["date"])
    end
    return unless actual && actual <= date && actual >= date - 5
    value = Provider::AccountData::OnchainWallet::SnapshotArchive.decimal(data.fetch("rate"))
    return unless value.positive?
    { "rate" => value.to_s("F"), "date" => actual.iso8601, "source" => "provider_response", "provider" => provider }
  rescue ArgumentError, TypeError, KeyError
    nil
  end

  def self.request(from:, to:, date:)
    unless [ from, to ].all? { |value| value.is_a?(String) && value.match?(/\A[A-Z]{3}\z/) } && from != to && date.instance_of?(Date)
      raise ArgumentError, "Wallet FX requires distinct currencies and an exact date"
    end
    { "from" => from, "to" => to, "date" => date.iso8601 }
  end

  def self.twelve_data_date(data)
    supplied = exact_date(data["date"]) if data["date"]
    timestamp = data["timestamp"]
    if timestamp
      return unless timestamp.is_a?(Integer) || (timestamp.is_a?(String) && timestamp.match?(/\A\d{1,12}\z/))
      number = timestamp.to_i
      return unless number.positive? && number <= 253_402_300_799
      dated = Time.at(number).utc.to_date
      return if supplied && supplied != dated
      return dated
    end
    supplied
  end

  def self.exact_date(value)
    return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    date = Date.iso8601(value)
    date if date.iso8601 == value
  end
  private_class_method :twelve_data_date, :exact_date

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def reject_transient!(code)
      if code.to_s == "429"
        raise Provider::AccountData::OnchainWallet::Readers::RateLimited, "Wallet FX endpoint rate limit exceeded"
      end
      if code.to_s.match?(/\A5\d\d\z/)
        raise Provider::AccountData::OnchainWallet::Readers::Error, "Wallet FX endpoint is unavailable"
      end
    end

    def provider
      @options.fetch("provider")
    end

    def envelope(request, status, code: nil, response: {})
      { "version" => 1, "provider" => provider, "request" => request, "status" => status, "http_status" => code, "response" => response }
    end
end
