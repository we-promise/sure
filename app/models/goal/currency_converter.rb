class Goal::CurrencyConverter
  # Shared by goals prepared for one page. Cache missing rates too: an unavailable
  # provider must not be called again for every balance, row and status pill.
  def initialize
    @rates = {}
  end

  def convert(money, to:, date: Date.current)
    to = Money::Currency.new(to).iso_code
    return Money.new(0, to) if money.zero?

    money.exchange_to(to, date: date, custom_rate: rate_for(money.currency.iso_code, to, date))
  end

  private
    def rate_for(from, to, date)
      return 1.to_d if from == to

      key = [ from, to, date ]
      unless @rates.key?(key)
        @rates[key] = ExchangeRate.find_or_fetch_rate(from: from, to: to, date: date)&.rate
      end
      rate = @rates[key]
      unless rate&.positive?
        raise Money::ConversionError.new(from_currency: from, to_currency: to, date: date)
      end
      rate
    end
end
