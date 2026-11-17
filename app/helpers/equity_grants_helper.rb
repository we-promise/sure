module EquityGrantsHelper
  def equity_grant_value_total(values, currency:, date:)
    values = values.compact
    return nil if values.empty?

    values.sum(Money.new(0, currency)) { |value| value.exchange_to(currency, date: date) }
  rescue Money::ConversionError
    nil
  end
end
