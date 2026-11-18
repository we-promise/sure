class Provider::Propertiesapi < Provider
  include PropertyValuationConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Propertiesapi::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # PropertiesAPI is prepaid per lookup, so this is a spending guard rather
  # than a plan limit. It matches the 50 lookups a new account gets for free.
  # Override with PROPERTIESAPI_MAX_REQUESTS_PER_MONTH.
  MAX_REQUESTS_PER_MONTH = 50

  # PropertiesAPI home types to Property::SUBTYPES keys. Unmapped types
  # (e.g. MANUFACTURED) leave the subtype unset rather than guessing.
  HOME_TYPE_MAP = {
    "SINGLE_FAMILY" => "single_family_home",
    "MULTI_FAMILY" => "multi_family_home",
    "CONDO" => "condominium",
    "TOWNHOUSE" => "townhouse",
    "APARTMENT" => "apartment",
    "LOT" => "plot"
  }.freeze

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # One address lookup returns the property record, including the Zestimate
  # shown on the home's public Zillow page, so no separate valuation request
  # is needed.
  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil)
    with_provider_response do
      throttle_request
      record_monthly_request!

      response = client.get("#{base_url}/v1/zillow/property") do |req|
        req.params["address"] = one_line_address(line1, locality, region, postal_code)
      end

      record = JSON.parse(response.body)["data"]
      raise Error.new(I18n.t("providers.propertiesapi.errors.not_found")) unless record.is_a?(Hash)

      # The address match is done by the API; this only refuses a record
      # whose ZIP contradicts the one the user entered.
      raise Error.new(I18n.t("providers.propertiesapi.errors.location_mismatch")) unless zip_match?(record, postal_code)

      # The Zestimate is null when Zillow shows none for the home. The listing
      # price is not used instead: for a rental it is the monthly rent.
      zestimate = record["zestimate"]
      raise Error.new(I18n.t("providers.propertiesapi.errors.no_valuation")) if zestimate.blank? || zestimate.to_d <= 0

      PropertyValuation.new(
        valuation: BigDecimal(zestimate.to_s),
        currency: "USD",
        property_type: HOME_TYPE_MAP[record["homeType"].to_s.upcase],
        year_built: record["yearBuilt"],
        area_value: record["livingArea"],
        area_unit: "sqft"
      )
    end
  end

  private
    attr_reader :api_key

    def one_line_address(line1, locality, region, postal_code)
      state_zip = [ region, postal_code ].map { |part| part.to_s.strip }.reject(&:empty?).join(" ")
      [ line1, locality, state_zip ].map { |part| part.to_s.strip }.reject(&:empty?).join(", ")
    end

    def zip_match?(record, postal_code)
      returned_zip = record["zipcode"].to_s.strip.first(5)
      entered_zip = postal_code.to_s.strip.first(5)

      returned_zip.blank? || entered_zip.blank? || returned_zip == entered_zip
    end

    def default_error_transformer(error)
      case error
      when Faraday::UnauthorizedError
        Error.new(I18n.t("providers.propertiesapi.errors.unauthorized"))
      when Faraday::ResourceNotFound
        Error.new(I18n.t("providers.propertiesapi.errors.not_found"))
      when Faraday::ConflictError
        Error.new(I18n.t("providers.propertiesapi.errors.ambiguous_address"))
      when Faraday::ClientError
        if error.response&.dig(:status) == 402
          Error.new(I18n.t("providers.propertiesapi.errors.no_credits"))
        else
          super
        end
      else
        super
      end
    end

    def base_url
      ENV["PROPERTIESAPI_URL"] || "https://api.propertiesapi.com"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        # Only connection failures are retried. Timeouts are not: each attempt
        # can take the full timeout, and failed lookups aren't charged, so the
        # next refresh simply tries again.
        faraday.request(:retry, {
          max: 2,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: [ Faraday::ConnectionFailed ]
        })
        faraday.request :json
        faraday.response :raise_error
        # A live lookup typically takes a few seconds; the API documents an
        # occasional one taking much longer and asks clients to wait 120s.
        faraday.options.timeout = 120
        faraday.options.open_timeout = 5
        faraday.headers["X-Api-Key"] = api_key
        faraday.headers["Accept"] = "application/json"
      end
    end
end
