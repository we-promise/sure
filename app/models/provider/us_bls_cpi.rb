class Provider::UsBlsCpi < Provider
  Error = Class.new(Provider::Error)

  DEFAULT_BASE_URL = "https://api.bls.gov/publicAPI/v2".freeze
  DEFAULT_SERIES_ID = "CUUR0000SA0".freeze

  def initialize(base_url: DEFAULT_BASE_URL, series_id: DEFAULT_SERIES_ID)
    @base_url = base_url
    @series_id = series_id
  end

  # Returns monthly CPI YoY index values for the given year (e.g. 103.4 means +3.4% YoY).
  def fetch_cpi_yoy_for_year(year:)
    with_provider_response do
      target_year = year.to_i
      raw_rows = fetch_series_rows(start_year: target_year - 1, end_year: target_year)
      index_by_month = raw_rows.each_with_object({}) do |row, memo|
        memo[[ row[:year], row[:month] ]] = row[:value]
      end

      (1..12).filter_map do |month|
        current = index_by_month[[ target_year, month ]]
        previous = index_by_month[[ target_year - 1, month ]]
        next if current.blank? || previous.blank? || previous.zero?

        { month:, rate_yoy: ((current / previous) * 100).round(3) }
      end
    end
  end

  private
    attr_reader :base_url, :series_id

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
      end
    end

    def fetch_series_rows(start_year:, end_year:)
      response = client.post("timeseries/data/") do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = {
          seriesid: [ series_id ],
          startyear: start_year.to_s,
          endyear: end_year.to_s
        }.to_json
      end

      parsed = JSON.parse(response.body)
      status = parsed["status"]
      raise Error.new("BLS API request failed with status #{status}") unless status == "REQUEST_SUCCEEDED"

      rows = parsed.dig("Results", "series", 0, "data") || []
      rows.filter_map do |row|
        period = row["period"].to_s
        next unless period.match?(/^M\d{2}$/)

        {
          year: row["year"].to_i,
          month: period.delete_prefix("M").to_i,
          value: row["value"].to_d
        }
      end
    end
end
