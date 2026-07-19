class Provider::Rentcast < Provider
  include PropertyValuationConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Rentcast::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # Maximum API requests per month (RentCast free tier limit).
  # Override with RENTCAST_MAX_REQUESTS_PER_MONTH for paid plans.
  MAX_REQUESTS_PER_MONTH = 50

  # RentCast property types to Property::SUBTYPES keys. Unmapped types
  # (e.g. "Manufactured") leave the subtype unset rather than guessing.
  PROPERTY_TYPE_MAP = {
    "Single Family" => "single_family_home",
    "Multi-Family" => "multi_family_home",
    "Condo" => "condominium",
    "Townhouse" => "townhouse",
    "Apartment" => "apartment",
    "Land" => "plot"
  }.freeze

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # Fetches the value estimate and the subject property's attributes in a
  # single request — `lookupSubjectAttributes` enriches the AVM response with
  # the property record, so a separate /v1/properties call isn't needed.
  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil)
    with_provider_response do
      throttle_request
      record_monthly_request!

      response = client.get("#{base_url}/v1/avm/value") do |req|
        req.params["address"] = [ line1, locality, region, postal_code ].map { |part| part.to_s.strip }.reject(&:empty?).join(", ")
        req.params["lookupSubjectAttributes"] = true
      end

      parsed = JSON.parse(response.body)
      price = parsed["price"]
      raise Error.new(I18n.t("providers.rentcast.errors.no_valuation")) if price.blank?

      subject = parsed["subjectProperty"] || {}

      PropertyValuation.new(
        valuation: price.to_d,
        currency: "USD",
        property_type: PROPERTY_TYPE_MAP[subject["propertyType"]],
        year_built: subject["yearBuilt"],
        area_value: subject["squareFootage"],
        area_unit: "sqft"
      )
    end
  end

  private
    attr_reader :api_key

    def default_error_transformer(error)
      case error
      when Faraday::ResourceNotFound
        Error.new(I18n.t("providers.rentcast.errors.not_found"))
      else
        super
      end
    end

    def base_url
      ENV["RENTCAST_URL"] || "https://api.rentcast.io"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        # Retry transient connection failures so a network blip doesn't burn
        # one of the tight monthly budget's requests
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })
        faraday.request :json
        faraday.response :raise_error
        faraday.options.timeout = 10
        faraday.options.open_timeout = 5
        faraday.headers["X-Api-Key"] = api_key
        faraday.headers["Accept"] = "application/json"
      end
    end
end
