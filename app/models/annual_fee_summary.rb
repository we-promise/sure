# Every credit card's annual fee and next charge date, with the totals the
# Annual fees page shows. Each date is worked out once, and each fee is
# converted to the family currency on its own, so one card without an
# exchange rate leaves the others in the totals and is counted separately.
class AnnualFeeSummary
  UPCOMING_DAYS = 60

  Row = Data.define(:card, :next_date, :days_until) do
    def fee? = card.annual_fee.to_d.positive?
    def upcoming? = fee? && days_until.present? && days_until <= UPCOMING_DAYS
  end

  Total = Data.define(:money, :card_count, :unconverted_count) do
    def complete? = unconverted_count.zero?
  end

  attr_reader :as_of, :currency, :rows

  def initialize(cards, currency:, as_of: Date.current)
    @as_of = as_of
    @currency = currency
    @rows = cards.map do |card|
      date = card.next_annual_fee_date(as_of: as_of)
      Row.new(card: card, next_date: date, days_until: date && (date - as_of).to_i)
    end
    # Cards with a renewal date first, soonest first; the rest by name.
    @rows.sort_by! { |row| [ row.next_date ? 0 : 1, row.next_date || Date.new(9999, 12, 31), row.card.account.name ] }
  end

  def with_fee = rows.select(&:fee?)

  def yearly = total(with_fee)

  def upcoming = total(rows.select(&:upcoming?))

  def next_fee = with_fee.find(&:next_date)

  private
    def total(selected)
      unconverted = 0
      sum = selected.sum(Money.new(0, currency)) do |row|
        row.card.annual_fee_money.exchange_to(currency, date: as_of)
      rescue Money::ConversionError
        unconverted += 1
        Money.new(0, currency)
      end
      # With nothing convertible there is no total to show, only the count.
      money = unconverted == selected.size && selected.any? ? nil : sum
      Total.new(money: money, card_count: selected.size, unconverted_count: unconverted)
    end
end
