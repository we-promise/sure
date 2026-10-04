class Provider::Terrascoutx < Provider
  include PropertyValuationConcept, RateLimitable
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Terrascoutx::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # Minimum delay between requests to avoid rate limiting (in seconds)
  MIN_REQUEST_INTERVAL = 1.0

  # Maximum API requests per month (TerraScoutX free tier limit).
  # Override with TERRASCOUTX_MAX_REQUESTS_PER_MONTH for paid plans.
  MAX_REQUESTS_PER_MONTH = 2000

  def initialize(api_key)
    @api_key = api_key # pipelock:ignore
  end

  # The address search returns full property records, best match first, so
  # a single request is enough. The value is the county assessor's roll
  # value (market value, else total appraised), not an automated estimate.
  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil)
    with_provider_response do
      throttle_request
      record_monthly_request!

      state = region.to_s.strip.upcase
      response = client.get("#{base_url}/v1/suggest") do |req|
        req.params["q"] = [ line1, locality, region, postal_code ].map { |part| part.to_s.strip }.reject(&:empty?).join(", ")
        req.params["limit"] = 5
        req.params["state"] = state if state.match?(/\A[A-Z]{2}\z/)
      end

      records = JSON.parse(response.body)["results"].to_a
      raise Error.new(I18n.t("providers.terrascoutx.errors.no_property")) if records.empty?

      record = records.find { |candidate| location_match?(candidate, line1: line1, postal_code: postal_code) }
      raise Error.new(I18n.t("providers.terrascoutx.errors.location_mismatch")) if record.nil?

      valuation = record.values_at("marketValue", "totalAppraised").find { |value| value.to_d.positive? }
      raise Error.new(I18n.t("providers.terrascoutx.errors.no_valuation")) if valuation.nil?

      PropertyValuation.new(
        valuation: BigDecimal(valuation.to_s),
        currency: "USD",
        property_type: subtype_for_land_use(record["landUse"]),
        year_built: record["yearBuilt"],
        area_value: record["livingAreaSqft"],
        area_unit: "sqft"
      )
    end
  end

  private
    attr_reader :api_key

    # The search is fuzzy, so a near miss (a neighbouring house number, the
    # same street in another ZIP) must not be taken as the user's property.
    # The city isn't compared: county rolls often record the municipality
    # rather than the mailing city.
    def location_match?(record, line1:, postal_code:)
      address = record["address"] || {}
      [
        [ house_number(address["street"]), house_number(line1) ],
        [ address["zip"].to_s.first(5), postal_code.to_s.strip.first(5) ]
      ].none? { |returned, entered| returned.present? && entered.present? && returned != entered }
    end

    def house_number(street)
      street.to_s[/\A\s*(\d+)/, 1]
    end

    # Land use is the county's own description, so it is matched on keywords.
    # Unmatched descriptions leave the subtype unset rather than guessing.
    def subtype_for_land_use(land_use)
      case land_use.to_s.downcase
      when /condo/ then "condominium"
      when /town.?(house|home)/ then "townhouse"
      when /single.?family|sfr/ then "single_family_home"
      when /multi.?family|duplex|triplex|fourplex/ then "multi_family_home"
      when /apartment/ then "apartment"
      when /agricultur|farm|ranch/ then "agri_land"
      when /commercial|retail|office|industrial/ then "commercial"
      when /vacant|\bland\b|\blots?\b/ then "plot"
      end
    end

    def base_url
      ENV["TERRASCOUTX_URL"] || "https://api.terrascoutx.com"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        # Retry transient connection failures so a network blip doesn't burn
        # one of the monthly budget's requests
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
