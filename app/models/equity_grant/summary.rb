# The figures the Equity grants tab shows for one account: unvested value,
# what vests in the next 12 months, the next vest, and the vest lists. Values
# are converted to the account currency one by one; a grant without a price or
# exchange rate is counted rather than dropped, so a partial total says so.
class EquityGrant::Summary
  Total = Data.define(:money, :unvalued_count) do
    def complete? = unvalued_count.zero?
  end

  attr_reader :account, :as_of, :grants

  def initialize(account, as_of: Date.current)
    @account = account
    @as_of = as_of
    @grants = account.equity_grants.includes(:vests, security: :prices).ordered.to_a
  end

  def any? = grants.any?

  def vests
    @vests ||= grants.flat_map { |grant| grant.vests.map { |vest| [ grant, vest ] } }
  end

  def upcoming
    vests.reject { |grant, vest| vest.vest_date <= as_of || vest.forfeited? }.sort_by { |_, vest| vest.vest_date }
  end

  def past
    vests.select { |_, vest| vest.vested?(as_of: as_of) }.sort_by { |_, vest| vest.vest_date }.reverse
  end

  def next_year
    upcoming.select { |_, vest| vest.vest_date <= as_of + 1.year }
  end

  def unvested_units = grants.sum { |grant| grant.unvested_units(as_of: as_of) }

  def unvested_total
    total(grants.select { |grant| grant.unvested_units(as_of: as_of).positive? }.map { |grant| grant.unvested_value(as_of: as_of) })
  end

  def next_year_total = total(next_year.map { |_, vest| vest.estimated_value })

  private
    def total(values)
      unvalued = 0
      sum = values.sum(Money.new(0, account.currency)) do |value|
        if value.nil?
          unvalued += 1
          next Money.new(0, account.currency)
        end
        value.exchange_to(account.currency, date: as_of)
      rescue Money::ConversionError
        unvalued += 1
        Money.new(0, account.currency)
      end
      Total.new(money: unvalued == values.size && values.any? ? nil : sum, unvalued_count: unvalued)
    end
end
