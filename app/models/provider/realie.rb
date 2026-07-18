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
      record = parsed["property"]
      record = record.first if record.is_a?(Array)
      raise Error.new("Realie did not return a property for this address") if record.blank?

      valuation = record["modelValue"] || record["totalMarketValue"]
      raise Error.new("Realie did not return a valuation for this property") if valuation.blank?

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

    # Realie use codes are free-form parcel descriptions (e.g. "Single Family
    # Residential"), so match on keywords rather than exact values. Unmatched
    # codes leave the subtype unset rather than guessing.
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
        Error.new("Realie could not find a property matching this address")
      else
        super
      end
    end

    def base_url
      ENV["REALIE_URL"] || "https://app.realie.ai"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Authorization"] = api_key
        faraday.headers["Accept"] = "application/json"
      end
    end
end
