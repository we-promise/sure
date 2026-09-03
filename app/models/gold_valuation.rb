# Calculates and records a physical-gold account's value. GoldAPI is queried at
# most once per quote currency per day; the resulting XAU rate is shared via the
# existing exchange_rates table.
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

      provider = Provider::Registry.get_provider(:gold_api)
      raise Error, "GoldAPI is not configured" unless provider.present?

      response = provider.fetch_gold_price(currency: account.currency)
      raise Error, response.error.message unless response.success?

      price = response.data
      # A refresh is a point-in-time valuation for the requested account date.
      # GoldAPI timestamps are UTC, which can otherwise put a late-night quote
      # into the prior local day and bypass this cache on the next refresh.
      ExchangeRate.create_or_find_by!(from_currency: "XAU", to_currency: account.currency, date: date) do |exchange_rate|
        exchange_rate.rate = price.price_per_troy_ounce
      end
      price
    end
end
