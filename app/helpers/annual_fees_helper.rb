module AnnualFeesHelper
  def annual_fee_total(cards, currency:, date:)
    cards.sum(Money.new(0, currency)) do |card|
      card.annual_fee_money.exchange_to(currency, date: date)
    end
  rescue Money::ConversionError
    nil
  end
end
