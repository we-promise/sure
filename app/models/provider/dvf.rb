require "csv"

# Values French properties from DVF (Demandes de valeurs foncières), the
# government's open record of every property sale, as republished with
# coordinates by Etalab (geo-DVF). Free and keyless: addresses are geocoded
# with the Géoplateforme geocoder and the estimate is computed locally by
# Provider::Dvf::Estimator.
class Provider::Dvf < Provider
  include PropertyValuationConcept
  extend SslConfigurable

  # Subclass so errors caught in this provider are raised as Provider::Dvf::Error
  Error = Class.new(Provider::Error)
  RateLimitError = Class.new(Error)

  # The data is free and unmetered; this only caps runaway refresh loops.
  # Override with DVF_MAX_REQUESTS_PER_MONTH.
  MAX_REQUESTS_PER_MONTH = 500

  # Sure subtypes DVF can value, by DVF `type_local`. A second home is a use,
  # not a structure (it can be an apartment), so it is not mapped.
  LOCAL_TYPES = {
    "apartment" => "Appartement",
    "condominium" => "Appartement",
    "single_family_home" => "Maison",
    "townhouse" => "Maison"
  }.freeze

  # Alsace-Moselle keeps its own land register (Livre foncier) and Mayotte
  # is not covered, so DVF has no sales there.
  UNCOVERED_DEPARTMENTS = %w[57 67 68 976].freeze

  # geo-DVF publishes one file per commune and year; the estimate looks back at
  # most 24 months from the newest sale, which lags today by 6 to 12 months.
  YEARS_BACK = 3

  def self.valuation_currency
    "EUR"
  end

  def self.supported_country
    "FR"
  end

  # The postcode is enough to geocode a French street address.
  def self.required_address_fields
    %i[line1 postal_code]
  end

  def self.accepts_square_footage?
    true
  end

  # DVF holds sales, not a record of each property, so the area is an input.
  def self.requires_area?
    true
  end

  def self.accepts_property_type?
    true
  end

  # DVF is republished twice a year (April and October).
  def self.refresh_interval
    1.month
  end

  def self.property_type_supported?(property_type)
    LOCAL_TYPES.key?(property_type.to_s)
  end

  def self.lookup_ready?(address, external_id = nil, **)
    super && UNCOVERED_DEPARTMENTS.none? { |department| address[:postal_code].to_s.strip.start_with?(department) }
  end

  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil, square_footage: nil, property_type: nil, **)
    with_provider_response do
      local_type = LOCAL_TYPES[property_type.to_s]
      raise Error.new(I18n.t("providers.dvf.errors.unsupported_property_type")) if local_type.nil?

      area = square_footage.to_d / Property::SQFT_PER_SQM
      raise Error.new(I18n.t("providers.dvf.errors.area_required")) unless area.positive?

      record_monthly_request!

      location = geocode([ line1, postal_code, locality ].compact_blank.join(" "), postal_code)
      rows = location[:communes].flat_map { |commune| rows_for(commune) }
      sales = Provider::Dvf::Estimator.sales_from_rows(rows, local_type: local_type)

      estimate = Provider::Dvf::Estimator.new(
        sales,
        latitude: location[:latitude],
        longitude: location[:longitude],
        area: area,
        radius: radius
      ).estimate
      raise Error.new(I18n.t("providers.dvf.errors.not_enough_sales")) if estimate.nil?

      PropertyValuation.new(
        valuation: BigDecimal(estimate.valuation),
        currency: valuation_currency,
        property_type: property_type.to_s,
        year_built: nil,
        area_value: area.round,
        area_unit: "sqm",
        valuation_low: BigDecimal(estimate.valuation_low),
        valuation_high: BigDecimal(estimate.valuation_high),
        confidence: estimate.confidence
      )
    end
  end

  private
    def radius
      ENV.fetch("DVF_RADIUS_METERS", Provider::Dvf::Estimator::DEFAULT_RADIUS).to_i
    end

    # Coordinates of the address and the communes whose sales can fall within
    # the widest search radius. DVF is filed per commune (per arrondissement in
    # Paris, Lyon and Marseille), so a property near a boundary needs its
    # neighbours too.
    def geocode(query, postal_code)
      response = client.get("#{geocoder_url}/search", { q: query, postcode: postal_code.to_s.strip, limit: 1 })
      feature = JSON.parse(response.body).dig("features", 0)
      raise Error.new(I18n.t("providers.dvf.errors.address_not_found")) if feature.nil?

      longitude, latitude = feature.dig("geometry", "coordinates")
      communes = [ feature.dig("properties", "citycode") ]

      reach = radius * 2 / 111_320.0
      [ [ reach, 0 ], [ -reach, 0 ], [ 0, reach ], [ 0, -reach ] ].each do |d_lat, d_lon|
        communes << commune_at(latitude + d_lat, longitude + d_lon / Math.cos(latitude * Math::PI / 180))
      end

      { latitude: latitude, longitude: longitude, communes: communes.compact.uniq }
    end

    # A failed lookup aborts the estimate: skipping a neighbouring commune
    # would value the property on an incomplete set of sales.
    def commune_at(latitude, longitude)
      response = client.get("#{geocoder_url}/reverse", { lat: latitude, lon: longitude, limit: 1 })
      JSON.parse(response.body).dig("features", 0, "properties", "citycode")
    rescue JSON::ParserError
      raise Error.new(I18n.t("providers.dvf.errors.unavailable"))
    end

    # Rows are grouped by mutation across every commune before sales are
    # picked, since a sale spanning two communes appears in both files.
    def rows_for(commune)
      current_year = Date.current.year
      (current_year - YEARS_BACK..current_year).flat_map do |year|
        Rails.cache.fetch([ "dvf", "rows", year, commune ], expires_in: 1.day) do
          commune_rows(commune, year)
        end
      end
    end

    def commune_rows(commune, year)
      department = commune.start_with?("97") ? commune[0, 3] : commune[0, 2]
      response = get_following_redirects("#{dvf_url}/#{year}/communes/#{department}/#{commune}.csv")
      CSV.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8), headers: true).map do |row|
        row.to_h.slice(*Provider::Dvf::Estimator::ROW_COLUMNS)
      end
    rescue Faraday::ResourceNotFound
      # The year isn't published yet, or the commune had no sales.
      []
    end

    # files.data.gouv.fr redirects each file to its object storage.
    def get_following_redirects(url, hops: 3)
      response = client.get(url)
      return response unless response.status.between?(300, 399) && response.headers["location"].present? && hops.positive?

      get_following_redirects(URI.join(url, response.headers["location"]).to_s, hops: hops - 1)
    end

    def default_error_transformer(error)
      case error
      when Error
        error
      when Faraday::TooManyRequestsError
        RateLimitError.new(I18n.t("providers.dvf.errors.unavailable"))
      when Faraday::ResourceNotFound
        Error.new(I18n.t("providers.dvf.errors.address_not_found"))
      when Faraday::Error
        Error.new(I18n.t("providers.dvf.errors.unavailable"))
      else
        super
      end
    end

    def geocoder_url
      ENV["DVF_GEOCODER_URL"] || "https://data.geopf.fr/geocodage"
    end

    def dvf_url
      ENV["DVF_URL"] || "https://files.data.gouv.fr/geo-dvf/latest/csv"
    end

    def client
      @client ||= Faraday.new(ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 2,
          interval: 1.0,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })
        faraday.response :raise_error
        faraday.options.timeout = 30
        faraday.options.open_timeout = 5
      end
    end
end
