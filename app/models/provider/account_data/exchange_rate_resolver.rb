# Application-bound rate lookup. Adapters capture each returned value and its
# actual date in encrypted page evidence; replay does not call this resolver.
class Provider::AccountData::ExchangeRateResolver
  def initialize
    @rates = {}
  end

  def call(from:, to:, date:)
    unless from.is_a?(String) && from.present? && to.is_a?(String) && to.present? && date.instance_of?(Date)
      raise ArgumentError, "Exchange rate needs currency codes and a date"
    end
    key = [ from, to, date ].freeze
    @rates.fetch(key) do
      @rates[key] = if from == to
        { rate: BigDecimal("1"), date: date.iso8601 }.freeze
      else
        result = ExchangeRate.find_or_fetch_rate(from: from, to: to, date: date)
        if result
          unless result.rate.is_a?(BigDecimal) && result.rate.finite? && result.rate.positive? && result.date.instance_of?(Date) && result.date <= date
            raise Provider::AccountData::InvalidResponse, "Invalid captured exchange rate"
          end
          { rate: result.rate, date: result.date.iso8601 }.freeze
        end
      end
    end
  end
end
