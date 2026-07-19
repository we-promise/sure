class Provider::Realie < Provider
  include PropertyValuationConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Realie::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # Maximum API requests per month (Realie free tier limit).
  # Override with REALIE_MAX_REQUESTS_PER_MONTH for paid plans.
  MAX_REQUESTS_PER_MONTH = 25

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # A single address lookup returns the full property record, including the
  # Realie model (AVM) value, so no separate valuation request is needed.
  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil)
    with_provider_response do
      throttle_request
      record_monthly_request!

      # The address lookup endpoint accepts only the street address and
      # 2-letter state code — filtering by city additionally requires a
      # county, which the property address form doesn't collect.
      response = client.get("#{base_url}/api/public/property/address/") do |req|
        req.params["address"] = line1.to_s.strip
        req.params["state"] = region.to_s.strip.upcase
      end

      parsed = JSON.parse(response.body)
      records = parsed["property"]
      records = [ records ] unless records.is_a?(Array)
      records = records.reject(&:blank?)
      raise Error.new(I18n.t("providers.realie.errors.no_property")) if records.empty?

      # A street+state query can return several candidates across different
      # cities; pick the first one consistent with the entered city/ZIP.
      record = records.find { |candidate| location_match?(candidate, locality: locality, postal_code: postal_code) }
      raise Error.new(I18n.t("providers.realie.errors.location_mismatch")) if record.nil?

      valuation = record["modelValue"] || record["totalMarketValue"]
      raise Error.new(I18n.t("providers.realie.errors.no_valuation")) if valuation.blank?

      PropertyValuation.new(
        valuation: valuation.to_d,
        currency: "USD",
        property_type: subtype_for_use_code(record["useCode"]),
        year_built: record["yearBuilt"],
        area_value: record["buildingArea"],
        area_unit: "sqft"
      )
    end
  end

  private
    attr_reader :api_key

    # The address lookup matches on street + state only (filtering by city
    # additionally requires a county, which isn't collected), so a common
    # street name can resolve to properties in other cities. A candidate
    # matches unless its returned city/ZIP contradict what the user entered.
    def location_match?(record, locality:, postal_code:)
      returned_city = record["city"].to_s.strip
      returned_zip = record["zipCode"].to_s.strip.first(5)
      entered_city = locality.to_s.strip
      entered_zip = postal_code.to_s.strip.first(5)

      city_mismatch = returned_city.present? && entered_city.present? && !returned_city.casecmp?(entered_city)
      zip_mismatch = returned_zip.present? && entered_zip.present? && returned_zip != entered_zip

      !(city_mismatch || zip_mismatch)
    end

    # Realie use codes can be free-form parcel descriptions (e.g. "Single
    # Family Residential"), so match on keywords rather than exact values.
    # Some counties return bare numeric codes (e.g. "1001") whose meanings
    # Realie doesn't publish — those (and any other unmatched codes) leave
    # the subtype unset rather than guessing.
    def subtype_for_use_code(use_code)
      value = use_code.to_s.downcase
      return nil if value.blank?

      case value
      when /single family|sfr/ then "single_family_home"
      when /multi.?family|duplex|triplex/ then "multi_family_home"
      when /condo/ then "condominium"
      when /town.?(house|home)/ then "townhouse"
      when /apartment/ then "apartment"
      when /agricultur|farm/ then "agri_land"
      when /commercial|retail|office|industrial/ then "commercial"
      when /vacant|land|lot/ then "plot"
      end
    end

    def default_error_transformer(error)
      case error
      when Faraday::ResourceNotFound
        Error.new(I18n.t("providers.realie.errors.not_found"))
      else
        super
      end
    end

    def base_url
      ENV["REALIE_URL"] || "https://app.realie.ai"
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
        faraday.headers["Authorization"] = api_key
        faraday.headers["Accept"] = "application/json"
      end
    end
end
