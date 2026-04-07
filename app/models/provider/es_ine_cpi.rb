class Provider::EsIneCpi < Provider
  Error = Class.new(Provider::Error)

  # Override via env when deploying, because INE endpoint can vary by dataset code.
  # Trailing slash required so Faraday appends series_id as a path segment, not a replacement.
  DEFAULT_BASE_URL = ENV["ES_INE_CPI_BASE_URL"].presence || "https://servicios.ine.es/wstempus/js/EN/DATOS_SERIE/".freeze

  def initialize(base_url: DEFAULT_BASE_URL, series_id: ENV["ES_INE_CPI_SERIES_ID"])
    # Ensure trailing slash for proper path segment appending
    @base_url = base_url&.end_with?("/") ? base_url : "#{base_url}/"
    @series_id = series_id
  end

  # Returns monthly CPI YoY index values for the given year (e.g. 102.7 means +2.7% YoY).
  # Expected payload supports records containing date + value pairs.
  def fetch_cpi_yoy_for_year(year:)
    with_provider_response do
      raise Error, "Missing ES_INE_CPI_SERIES_ID configuration" if series_id.blank?

      from = Date.new(year.to_i, 1, 1)
      to = Date.new(year.to_i, 12, 31)
      rows = fetch_rows(from:, to:)

      year_rows = rows.filter_map do |row|
        next unless row[:year] == year.to_i

        { month: row[:month], rate_yoy: row[:rate_yoy] }
      end

      raise Error, "No ES INE CPI data returned for #{year}" if year_rows.empty?

      year_rows
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

    def fetch_rows(from:, to:)
      response = client.get(series_id) do |req|
        req.params["tip"] = "AM"
        req.params["date"] = from.strftime("%Y%m%d")
        req.params["datef"] = to.strftime("%Y%m%d")
      end

      parsed = JSON.parse(response.body)
      records = parsed.is_a?(Array) ? parsed : Array(parsed["Data"] || parsed["data"])

      records.filter_map do |record|
        date = parse_date(record)
        value = parse_value(record)
        next if date.blank? || value.blank?

        { year: date.year, month: date.month, rate_yoy: value.to_d }
      end
    end

    def parse_date(record)
      raw = record["Fecha"] || record["fecha"] || record["date"]
      return nil if raw.blank?

      Date.parse(raw.to_s)
    rescue ArgumentError
      nil
    end

    def parse_value(record)
      raw = record["Valor"] || record["valor"] || record["value"]
      return nil if raw.blank?

      normalized = raw.to_s.tr(",", ".")
      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end
end
