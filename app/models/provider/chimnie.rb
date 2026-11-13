class Provider::Chimnie < Provider
  include PropertyValuationConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Chimnie::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Chimnie's free UPRN valuations are limited to 1 request per second.
  MIN_REQUEST_INTERVAL = 1.1

  # UPRN valuations are free, so this is a safety cap rather than a plan
  # limit. Override with CHIMNIE_MAX_REQUESTS_PER_MONTH.
  MAX_REQUESTS_PER_MONTH = 1000

  # Only these fields are free when requested by UPRN — asking for anything
  # else (property type, floor area, ...) makes the request billable.
  FREE_VALUATION_FIELDS = %w[
    property.value.sale.property_value
    property.value.sale.property_value_range
    property.value.sale.property_value_confidence
  ].freeze

  UPRN_FORMAT = /\A\d{1,12}\z/

  # Runs a hook immediately before every HTTP attempt, including retries, so
  # each one is throttled and counted against the monthly budget.
  class BeforeEachAttempt < Faraday::Middleware
    def initialize(app, hook)
      super(app)
      @hook = hook
    end

    def on_request(_env)
      @hook.call
    end
  end

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # Looks up a UK residential property by its UPRN (Unique Property
  # Reference Number). The address isn't sent — UPRN lookups are free,
  # address lookups are charged.
  def fetch_property_valuation(line1: nil, locality: nil, region: nil, postal_code: nil, external_id: nil)
    with_provider_response do
      uprn = self.class.normalize_uprn(external_id)
      raise Error.new(I18n.t("providers.chimnie.errors.invalid_uprn")) if uprn.nil?

      response = client.get("#{base_url}/residential/uprn/#{uprn}") do |req|
        req.params["fields"] = FREE_VALUATION_FIELDS.join(",")
      end

      parsed = JSON.parse(response.body)
      sale = parsed.dig("property", "value", "sale") || {}
      value = sale["property_value"]
      raise Error.new(I18n.t("providers.chimnie.errors.no_estimate")) if value.blank? || value.to_d <= 0

      low, high = Array(sale["property_value_range"])

      PropertyValuation.new(
        valuation: BigDecimal(value.to_s),
        currency: valuation_currency,
        property_type: nil,
        year_built: nil,
        area_value: nil,
        area_unit: "sqft",
        external_id: parsed["id"].presence&.to_s || uprn,
        valuation_low: low.present? ? BigDecimal(low.to_s) : nil,
        valuation_high: high.present? ? BigDecimal(high.to_s) : nil,
        confidence: sale["property_value_confidence"].presence&.downcase
      )
    end
  end

  # Strips the spaces people copy from council tax bills; returns nil when
  # the result isn't a valid UPRN.
  def self.normalize_uprn(value)
    uprn = value.to_s.gsub(/\s+/, "")
    uprn.match?(UPRN_FORMAT) ? uprn : nil
  end

  def self.valuation_currency
    "GBP"
  end

  def self.supported_country
    "GB"
  end

  def self.requires_external_id?
    true
  end

  # The address is kept for display only; lookups go by UPRN. UK addresses
  # often have no county, so region isn't required.
  def self.required_address_fields
    %i[line1 postal_code]
  end

  # AVM estimates don't move day to day; refreshing monthly keeps well
  # inside the free tier's rate limit.
  def self.refresh_interval
    1.month
  end

  private
    attr_reader :api_key

    def default_error_transformer(error)
      case error
      when Faraday::UnauthorizedError
        Error.new(I18n.t("providers.chimnie.errors.unauthorized"))
      when Faraday::ResourceNotFound
        Error.new(I18n.t("providers.chimnie.errors.not_found"))
      when Faraday::ConflictError
        Error.new(I18n.t("providers.chimnie.errors.unsupported_property"))
      when Faraday::ClientError
        if error.response&.dig(:status) == 402
          Error.new(I18n.t("providers.chimnie.errors.insufficient_balance"))
        else
          super
        end
      else
        super
      end
    end

    def base_url
      ENV["CHIMNIE_URL"] || "https://api.chimnie.com"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        # 429s are retried too: the 1 request/second limit is per API key, so
        # concurrent lookups or refresh jobs in other processes can trip it
        # despite the per-instance throttle. Chimnie sends no Retry-After, so
        # back off from 1s.
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed, Faraday::TooManyRequestsError ]
        })
        # After the retry middleware, so it runs for each attempt.
        faraday.use BeforeEachAttempt, -> {
          throttle_request
          record_monthly_request!
        }
        faraday.request :json
        faraday.response :raise_error
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
        faraday.headers["Authorization"] = "Bearer #{api_key}"
        faraday.headers["Accept"] = "application/json"
      end
    end
end
