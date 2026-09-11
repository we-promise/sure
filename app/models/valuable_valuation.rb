# Values bullion from its material's spot quote. Gems and stones require a
# manual or appraised value because carat alone does not establish a price.
class ValuableValuation
  Error = Class.new(StandardError)

  def initialize(account:, date: Date.current, reconciliation_name: nil)
    @account = account
    @date = date
    @reconciliation_name = reconciliation_name
  end

  def refresh!
    validate_account!
    rates = spot_symbols.index_with { |symbol| rate_for(symbol) }

    account.with_lock do
      account.reload
      validate_account!
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
      cached = ExchangeRate.find_by(from_currency: symbol, to_currency: account.currency, date: date)
      return price_from_rate(cached, symbol) if cached

      price = fetch_twelve_data_price(symbol) { |error| log_twelve_data_fallback(symbol, error) } || fetch_gold_api_price(symbol)
      raise Error, "No bullion price provider is configured for #{symbol}" unless price
      unless price.date == date && price.currency == account.currency && price.price_per_troy_ounce.to_d > 0
        raise Error, "The bullion provider returned an invalid or stale #{symbol} quote"
      end

      cached = ExchangeRate.create_or_find_by!(from_currency: symbol, to_currency: account.currency, date: date) { |rate| rate.rate = price.price_per_troy_ounce }
      price_from_rate(cached, symbol)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      cached = ExchangeRate.find_by(from_currency: symbol, to_currency: account.currency, date: date)
      raise unless cached
      price_from_rate(cached, symbol)
    end

    def price_from_rate(rate, symbol)
      raise Error, "The cached #{symbol} quote is invalid" unless rate.rate.to_d > 0
      Provider::GoldApi::Price.new(date: rate.date, currency: account.currency, price_per_troy_ounce: rate.rate, symbol: symbol)
    end

    def fetch_twelve_data_price(symbol)
      provider = Provider::Registry.get_provider(:twelve_data)
      return unless provider.present?
      response = symbol == "XAU" ? provider.fetch_gold_price(date:) : provider.fetch_bullion_price(symbol:, date:)
      if response.success? && response.data
        price = convert_twelve_data_price(response.data)
        return price if price&.price_per_troy_ounce.to_d&.positive? && price.date == date
      end
      yield(response.error || Provider::TwelveData::Error.new("#{symbol} spot quote or currency conversion unavailable")) if block_given?
      nil
    end

    def log_twelve_data_fallback(symbol, error)
      DebugLogEntry.capture(category: symbol == "XAU" ? "gold_valuation" : "valuable_valuation", level: "warn", message: "Twelve Data #{symbol} quote unavailable; falling back to GoldAPI", source: "ValuableValuation#fetch_twelve_data_price", provider_key: "twelve_data", family: account.family, account: account, metadata: { account_id: account.id, symbol: symbol, error: error.message, failure_code: error.respond_to?(:failure_code) ? error.failure_code : nil })
    end

    def convert_twelve_data_price(price)
      return price if account.currency == "USD"
      fx_rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: account.currency, date: date)
      return unless fx_rate.present?
      Provider::TwelveData::BullionPrice.new(date: date, currency: account.currency, price_per_troy_ounce: price.price_per_troy_ounce.to_d * fx_rate.rate.to_d, symbol: price.symbol)
    end

    def fetch_gold_api_price(symbol)
      provider = Provider::Registry.get_provider(:gold_api)
      return unless provider.present?
      response = symbol == "XAU" ? provider.fetch_gold_price(currency: account.currency) : provider.fetch_bullion_price(symbol:, currency: account.currency)
      raise Error, response.error&.message || "GoldAPI could not provide a #{symbol} price" unless response.success?
      response.data
    end
end
