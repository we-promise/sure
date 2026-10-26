# Values bullion from its material's spot quote. Gems and stones require a
# manual or appraised value because carat alone does not establish a price.
class ValuableValuation
  Error = Class.new(StandardError)

  QUOTE_SOURCES = {
    "twelve_data" => :fetch_twelve_data_price,
    "goldapi_io" => :fetch_gold_api_price,
    "gold_api_com" => :fetch_gold_api_com_price
  }.freeze
  PROVISIONAL_REFETCH_AFTER = 1.hour

  def initialize(account:, date: Date.current, reconciliation_name: nil)
    @account = account
    @date = date
    @reconciliation_name = reconciliation_name
  end

  def refresh!
    validate_account!
    valuation_currency = account.currency
    rates = spot_symbols.index_with { |symbol| rate_for(symbol) }

    account.with_lock do
      account.reload
      validate_account!
      raise Error, "Account currency changed during valuation; refresh again" if account.currency != valuation_currency

      items = account.valuable.items.reload
      missing = items.select(&:spot_valued?).map(&:quote_symbol).uniq - rates.keys
      raise Error, "Purchases changed during valuation; refresh again" if missing.any?

      value = items.sum { |item| item.value_for(rates[item.quote_symbol]&.price_per_troy_ounce) }
      result = account.set_current_balance(value, reconciliation_name: @reconciliation_name)
      raise Error, result.error unless result.success?

      account.valuable.update!(valuation_pending: false, valued_at: Time.current)
      value
    end
  rescue Error, ActiveRecord::RecordInvalid
    account.valuable&.update_columns(valuation_pending: true) if account.valuable?
    raise
  end

  private
    attr_reader :account, :date

    def validate_account!
      raise Error, "This account is not a Gems and Bullion asset" unless account.valuable?
      raise Error, "Spot prices can only be refreshed for today" unless date == Date.current
    end

    def spot_symbols
      account.valuable.items.spot_valued.map(&:quote_symbol).compact.uniq
    end

    def rate_for(symbol)
      cached = cached_rate(symbol)
      return price_from_rate(cached, symbol) if cached && !refetch?(cached)

      with_spot_rate_lock(symbol) do
        cached = cached_rate(symbol)
        return price_from_rate(cached, symbol) if cached && !refetch?(cached)

        price, source = fetch_quote(symbol)
        unless price
          return price_from_rate(cached, symbol) if cached
          raise Error, "No bullion price provider could provide a current #{symbol} quote"
        end

        # Spot quotes are intraday, so they only replace provisional rows: an
        # earlier quote or a futures value, never a close.
        rate = ExchangeRate.find_or_initialize_by(from_currency: symbol, to_currency: account.currency, date: date)
        rate.update!(rate: price.price_per_troy_ounce, source: source, provisional: true) if rate.new_record? || rate.provisional?
        price_from_rate(rate, symbol)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      cached = cached_rate(symbol)
      raise unless cached
      price_from_rate(cached, symbol)
    end

    def cached_rate(symbol)
      ExchangeRate.find_by(from_currency: symbol, to_currency: account.currency, date: date)
    end

    def refetch?(rate)
      rate.provisional? && (rate.source == "yahoo_futures" || rate.updated_at < PROVISIONAL_REFETCH_AFTER.ago)
    end

    # Returns [price, source] from the first provider with a valid quote for
    # today, recording each provider that fails along the way.
    def fetch_quote(symbol)
      QUOTE_SOURCES.each do |source, fetcher|
        price = send(fetcher, symbol) { |error| log_quote_failure(symbol, source, error) }
        next unless price

        if price.date == date && price.currency == account.currency && price.price_per_troy_ounce.to_d > 0
          return [ price, source ]
        end
        log_quote_failure(symbol, source, Error.new("#{source} returned an invalid or stale #{symbol} quote"))
      end
      nil
    end

    def price_from_rate(rate, symbol)
      raise Error, "The cached #{symbol} quote is invalid" unless rate.rate.to_d > 0
      Provider::GoldApi::Price.new(date: rate.date, currency: account.currency, price_per_troy_ounce: rate.rate, symbol: symbol)
    end

    def with_spot_rate_lock(symbol)
      key = "#{symbol}:#{account.currency}:#{date.iso8601}"
      db_connection = ExchangeRate.connection
      db_connection.execute(advisory_lock_sql("pg_advisory_lock", key))
      locked = true
      yield
    ensure
      db_connection.execute(advisory_lock_sql("pg_advisory_unlock", key)) if locked
    end

    def advisory_lock_sql(function, key)
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT #{function}(hashtext(?), hashtext(?))", "valuable_spot_rate", key ]
      )
    end

    def fetch_twelve_data_price(symbol)
      provider = Provider::Registry.get_provider(:twelve_data)
      return unless provider.present?
      response = symbol == "XAU" ? provider.fetch_gold_price(date:) : provider.fetch_bullion_price(symbol:, date:)
      if response.success? && response.data
        price = convert_usd_price(response.data)
        return price if price &&
          price.price_per_troy_ounce.present? &&
          price.price_per_troy_ounce.to_d.positive? &&
          price.date == date
      end
      yield(response.error || Provider::TwelveData::Error.new("#{symbol} spot quote or currency conversion unavailable")) if block_given?
      nil
    end

    def log_quote_failure(symbol, source, error)
      DebugLogEntry.capture(category: symbol == "XAU" ? "gold_valuation" : "valuable_valuation", level: "warn", message: "#{source} #{symbol} quote unavailable", source: "ValuableValuation#fetch_quote", provider_key: source, family: account.family, account: account, metadata: { account_id: account.id, symbol: symbol, error: error.message, failure_code: error.respond_to?(:failure_code) ? error.failure_code : nil })
    end

    def convert_usd_price(price)
      return price if account.currency == "USD"
      fx_rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: account.currency, date: date)
      return unless fx_rate.present?
      Provider::GoldApi::Price.new(date: date, currency: account.currency, price_per_troy_ounce: price.price_per_troy_ounce.to_d * fx_rate.rate.to_d, symbol: price.symbol)
    end

    def fetch_gold_api_price(symbol)
      provider = Provider::Registry.get_provider(:gold_api)
      return unless provider.present?
      response = symbol == "XAU" ? provider.fetch_gold_price(currency: account.currency) : provider.fetch_bullion_price(symbol:, currency: account.currency)
      return response.data if response.success?
      yield(response.error || Provider::GoldApi::Error.new("GoldAPI could not provide a #{symbol} price"))
      nil
    end

    def fetch_gold_api_com_price(symbol)
      provider = Provider::Registry.get_provider(:gold_api_com)
      return unless provider.present?
      response = provider.fetch_bullion_price(symbol:)
      price = convert_usd_price(response.data) if response.success?
      return price if price
      yield(response.error || Provider::GoldApiCom::Error.new("#{symbol} spot quote or currency conversion unavailable"))
      nil
    end
end
