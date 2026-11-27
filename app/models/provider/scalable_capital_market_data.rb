class Provider::ScalableCapitalMarketData < Provider
  include SecurityConcept

  KEY = "scalable_capital_market_data"
  ZONE = "Europe/Berlin"
  ISIN = /\A[A-Z]{2}[A-Z0-9]{9}\d\z/
  TIMEFRAMES = { 25 => "one_month", 80 => "three_months", 165 => "six_months", 345 => "one_year" }.freeze

  def self.connection
    family_id = ScalableCapitalItem.configured_family_id
    return unless family_id

    item = ScalableCapitalItem.find_by(family_id: family_id)
    item if item&.broker_account_id.present? && item.market_data_portfolio_id.present?
  end

  def self.supports_symbol?(symbol)
    symbol.to_s.match?(ISIN)
  end

  def initialize(item, client: Provider::ScalableCapital.new)
    @item = item
    @portfolio_id = item.market_data_portfolio_id
    @client = client
  end

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      next [] if exchange_operating_mic.present?

      query = symbol.to_s.strip
      rows = broker_result { @client.search_securities(@portfolio_id, query) }["items"]
      raise Error, "Scalable returned an invalid security list" unless rows.is_a?(Array)

      rows.filter_map do |row|
        next unless row.is_a?(Hash) && self.class.supports_symbol?(row["isin"]) && row["name"].is_a?(String)

        # The CLI exposes the ISIN as the stable lookup identifier.
        Security.new(symbol: row["isin"], isin: row["isin"], name: row["name"], currency: currency(row["quote_currency"]),
                     exchange_operating_mic: nil, country_code: nil, logo_url: nil)
      end.uniq(&:isin)
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      validate_security!(symbol, exchange_operating_mic)
      data = quote(symbol)
      SecurityInfo.new(symbol: symbol, name: data["name"], kind: data["security_type"], exchange_operating_mic: nil,
                       logo_url: nil, links: nil, description: nil)
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic:, date:)
    with_provider_response do
      validate_security!(symbol, exchange_operating_mic)

      result = if date < Date.current
        historical_prices(symbol, date, date).first
      elsif date == Date.current
        current_quote(symbol, date)
      end
      result || raise(Error.new("No Scalable price for the requested date", failure_code: :no_price))
    end
  end

  def fetch_security_health_price(symbol:, exchange_operating_mic:, date:)
    response = fetch_security_price(symbol: symbol, exchange_operating_mic: exchange_operating_mic, date: date)
    return response unless response.error&.failure_code == :no_price

    with_provider_response do
      historical_prices(symbol, date - 7, date).last ||
        raise(Error.new("No recent Scalable closing price", failure_code: :no_price))
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
    with_provider_response do
      validate_security!(symbol, exchange_operating_mic)
      historical_prices(symbol, start_date, end_date)
    end
  end

  private

    def validate_security!(symbol, mic)
      raise Error, "Scalable prices require an ISIN and a consolidated listing" unless self.class.supports_symbol?(symbol) && mic.blank?
    end

    def with_verified_session
      ScalableCapitalItem.with_cli_lock do
        unless @client.identity == @item.broker_account_id
          raise Error, "Sign in with the original Scalable account in read-only mode"
        end

        yield
      end
    end

    def broker_result
      data = with_verified_session { yield }
      unless data["account_id"] == @item.broker_account_id && data["portfolio_id"] == @portfolio_id && data["result"].is_a?(Hash)
        raise Error, "Scalable returned a different account or portfolio"
      end

      data.fetch("result")
    end

    def quote(isin)
      data = broker_result { @client.security_quote(@portfolio_id, isin) }
      raise Error, "Scalable returned a different security" unless data["isin"] == isin

      data
    end

    def current_quote(isin, date)
      data = quote(isin)
      time = timestamp(data["quote_timestamp_utc"])
      return unless data["quote_is_outdated"] == false && time && time.in_time_zone(ZONE).to_date == date && time <= Time.current

      price(isin, date, data["quote_mid_price"], currency(data["quote_currency"]))
    end

    def historical_prices(isin, start_date, end_date)
      return [] if start_date > end_date || start_date > Date.current

      timeframe = TIMEFRAMES.find { |days, _| (Date.current - start_date) <= days }&.last || "max"
      data = with_verified_session { @client.security_candlesticks(isin, timeframe) }
      code = currency(data["currency"])
      unless data["isin"] == isin && data["source"] == "consolidated" && code && data["candlesticks"].is_a?(Array)
        raise Error, "Scalable returned invalid candlesticks"
      end

      closes = {}
      data.fetch("candlesticks").each do |bar|
        next unless bar.is_a?(Hash)

        start = timestamp(bar["start_time_utc"])
        finish = timestamp(bar["end_time_utc"])
        next unless start && finish && finish >= start && finish <= Time.current && finish - start <= 25.hours

        date = start.in_time_zone(ZONE).to_date
        next unless (start_date..end_date).cover?(date)

        close = price(isin, date, bar["close"], code)
        closes[date] = [ finish, close ] if close && (closes[date].nil? || finish > closes[date].first)
      end
      closes.sort.map { |_, (_, close)| close }
    end

    def timestamp(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end

    def currency(value)
      value if value.is_a?(String) && value.match?(/\A[A-Z]{3}\z/)
    end

    def price(isin, date, value, currency)
      return unless currency && (value.is_a?(String) || value.is_a?(Numeric))

      amount = BigDecimal(value.to_s, exception: false)
      return unless amount&.finite? && amount.positive?

      Price.new(symbol: isin, date: date, price: amount, currency: currency, exchange_operating_mic: nil)
    end
end
