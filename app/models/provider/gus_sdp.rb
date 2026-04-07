class Provider::GusSdp < Provider
  Error = Class.new(Provider::Error)

  DEFAULT_BASE_URL = "https://api-sdp.stat.gov.pl/api".freeze
  # CPI (consumer prices) monthly indicator used by GUS SDP.
  # 1832 = "analogiczny okres roku poprzedniego=100" (YoY index, id-sposob-prezentacji-miara=5).
  # 639  = "okres poprzedni=100" (MoM index) — do NOT use for bond inflation calculations.
  DEFAULT_CPI_INDICATOR_ID = 1832

  # Optional GUS SDP client identifier (X-ClientId header). Not a secret — public API identifier.
  # Set via ENV["GUS_SDP_API_KEY"] or the hosting settings page.
  def initialize(client_id: nil, base_url: DEFAULT_BASE_URL, cpi_indicator_id: DEFAULT_CPI_INDICATOR_ID)
    @client_id = client_id
    @base_url = base_url
    @cpi_indicator_id = cpi_indicator_id
  end

  def fetch_cpi_yoy_for_year(year:)
    with_provider_response do
      response = client.get("indicators/indicator-data-indicator") do |req|
        req.params["id-wskaznik"] = cpi_indicator_id
        req.params["id-rok"] = year
        req.params["lang"] = "pl"
      end

      parsed = JSON.parse(response.body)
      rows = if parsed.is_a?(Array)
        parsed
      elsif parsed.is_a?(Hash)
        parsed.fetch("data", [])
      else
        []
      end

      rows.filter_map do |row|
        period_id = row["id-okres"] || row["period_id"]
        value = row["wartosc"] || row["value"] || row["rate_yoy"]
        next if period_id.blank? || value.blank?

        {
          period_id: period_id,
          value: value
        }
      end
    end
  end

  private
    attr_reader :client_id, :base_url, :cpi_indicator_id

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 4,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [ 429, 500, 502, 503, 504 ]
        })
        faraday.options.timeout = 10
        faraday.options.open_timeout = 10
        faraday.response :raise_error
        faraday.headers["X-ClientId"] = client_id if client_id.present?
      end
    end
end
