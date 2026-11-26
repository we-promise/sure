# The numbers above the purchases list: what was spent this month, what still waits for a payment
# and the shop bought from most. Orders that weren't added or couldn't be read don't count as
# spending. Amounts aren't converted: other currencies are reported beside the family's own.
class Purchase::Summary
  NOT_SPENDING = %w[processing rejected failed].freeze

  Result = Data.define(:spent, :other_spent, :purchases_count, :items_count, :to_match_count, :top_merchant, :top_merchant_count)

  # @return [Hash{Date, nil => Array<Money>}] totals per month (nil for undated orders), the
  #   family's currency first. An order with no currency is counted in the family's; one in a
  #   currency Money doesn't know is left out rather than breaking the page.
  def self.month_totals(scope, currency:)
    sums = scope.unscope(:order, :includes).where.not(status: NOT_SPENDING).where.not(total: nil)
      .group(Arel.sql("date_trunc('month', purchases.ordered_on)::date"), :currency)
      .sum(:total)

    sums.each_with_object({}) do |((month, code), sum), totals|
      code = code.to_s.strip.upcase.presence || currency
      next unless known_currency?(code)

      by_code = totals[month] ||= Hash.new(0)
      by_code[code] += sum
    end.transform_values do |by_code|
      by_code.sort_by { |code, _| [ code == currency ? 0 : 1, code ] }.map { |code, sum| Money.new(sum, code) }
    end
  end

  def self.known_currency?(code)
    Money::Currency.new(code)
    true
  rescue Money::Currency::UnknownCurrencyError
    false
  end
  private_class_method :known_currency?

  def initialize(scope, currency:, month: Date.current)
    @scope = scope.unscope(:order, :includes)
    @currency = currency
    @month = month
  end

  def call
    totals = self.class.month_totals(spending, currency:)[month.beginning_of_month] || []
    own, other = totals.partition { _1.currency.iso_code == currency }
    top_merchant, top_merchant_count = spending.where.not(merchant: [ nil, "" ]).group(:merchant).order(Arel.sql("COUNT(*) DESC"), :merchant).limit(1).count.first

    Result.new(
      spent: own.first || Money.new(0, currency),
      other_spent: other,
      purchases_count: spending.count,
      items_count: PurchaseItem.where(purchase_id: spending.select(:id)).count,
      to_match_count: scope.to_match.count,
      top_merchant:,
      top_merchant_count: top_merchant_count.to_i
    )
  end

  private
    attr_reader :scope, :currency, :month

    def spending
      @spending ||= scope.where(ordered_on: month.all_month).where.not(status: NOT_SPENDING)
    end
end
