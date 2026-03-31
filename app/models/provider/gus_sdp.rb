class Provider::GusSdp < Provider
  Error = Class.new(Provider::Error)

  DEFAULT_BASE_URL = "https://api-sdp.stat.gov.pl/api".freeze
  # CPI (consumer prices) monthly indicator used by GUS SDP.
  DEFAULT_CPI_INDICATOR_ID = 639

  def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, cpi_indicator_id: DEFAULT_CPI_INDICATOR_ID)
    @api_key = api_key
    @base_url = base_url
    @cpi_indicator_id = cpi_indicator_id
  end

  def fetch_cpi_yoy_for_year(year:)
    with_provider_response do
      response = client.get("/indicators/indicator-data-indicator") do |req|
        req.params["id-wskaznik"] = cpi_indicator_id
        req.params["id-rok"] = year
        req.params["lang"] = "pl"
      end

      parsed = JSON.parse(response.body)
      rows = parsed.is_a?(Array) ? parsed : parsed.fetch("data", [])

      rows.map do |row|
        {
          period_id: row["id-okres"],
          value: row["wartosc"]
        }
      end
    end
  end

  private
    attr_reader :api_key, :base_url, :cpi_indicator_id

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        faraday.request(:retry, {
          max: 4,
          interval: 0.5,
          interval_randomness: 0.5,
          backoff_factor: 2,
          retry_statuses: [ 429, 500, 502, 503, 504 ]
        })
        faraday.response :raise_error
        faraday.headers["X-ClientId"] = api_key if api_key.present?
      end
    end
end
