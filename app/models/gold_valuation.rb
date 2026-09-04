# Calculates and records a physical-gold account's value. A configured Twelve
# Data provider is preferred, with GoldAPI as a fallback. The resulting XAU
# rate is shared via the existing exchange_rates table once per quote currency
# per day.
class GoldValuation
  TROY_OUNCE_GRAMS = BigDecimal("31.1034768")

  Error = Class.new(StandardError)

  def initialize(account:, date: Date.current)
    @account = account
    @date = date
  end

  def refresh!
    validate_account!
    rate = gold_rate

    account.with_lock do
      account.reload
      validate_account!
      value = account.investment.gold_value_for(rate.price_per_troy_ounce)
      result = account.set_current_balance(value)
      raise Error, result.error unless result.success?

      value
    end
  end

  private
    attr_reader :account, :date

    def validate_account!
      raise Error, "This account is not a physical gold investment" unless account.investment? && account.investment.physical_gold?
      raise Error, "Add at least one physical gold purchase before refreshing its valuation" unless account.investment.gold_details_complete?
    end

    def gold_rate
      return Provider::GoldApi::Price.new(date:, currency: account.currency, price_per_troy_ounce: 0) unless account.investment.gold_spot_price_required?

      cached = ExchangeRate.find_by(from_currency: "XAU", to_currency: account.currency, date: date)
      return Provider::GoldApi::Price.new(date:, currency: account.currency, price_per_troy_ounce: cached.rate) if cached.present?

      price = fetch_twelve_data_gold_price || fetch_gold_api_price
      raise Error, "No physical gold price provider is configured" unless price.present?

      exchange_rate = ExchangeRate.create_or_find_by!(from_currency: "XAU", to_currency: account.currency, date: date) do |exchange_rate|
        exchange_rate.rate = price.price_per_troy_ounce
      end
      Provider::GoldApi::Price.new(
        date: exchange_rate.date,
        currency: account.currency,
        price_per_troy_ounce: exchange_rate.rate
      )
    end

    def fetch_twelve_data_gold_price
      provider = Provider::Registry.get_provider(:twelve_data)
      return unless provider.present?

      response = provider.fetch_gold_price(date:)
      return convert_twelve_data_price(response.data) if response.success?

      DebugLogEntry.capture(
        category: "gold_valuation",
        level: "warn",
        message: "Twelve Data Gold Spot quote unavailable; falling back to GoldAPI",
        source: "GoldValuation#fetch_twelve_data_gold_price",
        provider_key: "twelve_data",
        family: account.family,
        account: account,
        metadata: {
          account_id: account.id,
          error: response.error&.message,
          failure_code: response.error&.failure_code
        }
      )

      nil
    end

    def convert_twelve_data_price(price)
      return price if account.currency == "USD"

      fx_rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: account.currency, date: date)
      return unless fx_rate.present?

      Provider::TwelveData::GoldPrice.new(
        date:,
        currency: account.currency,
        price_per_troy_ounce: price.price_per_troy_ounce.to_d * fx_rate.rate.to_d
      )
    end

    def fetch_gold_api_price
      provider = Provider::Registry.get_provider(:gold_api)
      return unless provider.present?

      response = provider.fetch_gold_price(currency: account.currency)
      raise Error, response.error&.message || "GoldAPI could not provide a gold price" unless response.success?

      response.data
    end
end
