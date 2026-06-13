# Tracks weighted-average cost basis for a single security as trades are
# applied in chronological order.
#
# Buys add to the running cost and quantity. Sells relieve quantity at the
# current average cost (leaving the per-share average unchanged), and once the
# position is fully closed the tracker resets so a later repurchase starts from
# a clean basis. Without this relief, cost basis would be averaged over every
# buy the account ever made for the security — corrupting the figure after a
# position is sold off and bought again.
#
# Prices are expected in the account's currency (callers convert before
# applying), so the tracker itself is currency-agnostic.
class Holding::CostBasisTracker
  def initialize
    @total_cost = BigDecimal("0")
    @total_qty = BigDecimal("0")
  end

  # Applies a trade by its signed quantity: positive is a buy, negative a sell.
  def apply(price, qty)
    return if qty.nil?

    qty = qty.to_d
    return if qty.zero?

    qty.positive? ? buy(price, qty) : sell(qty)
  end

  def buy(price, qty)
    price = price&.to_d
    qty = qty&.to_d
    return if price.nil? || qty.nil? || !qty.positive?

    @total_cost += price * qty
    @total_qty += qty
  end

  def sell(qty)
    qty = qty&.to_d
    return if qty.nil? || qty.zero? || @total_qty.zero?

    # Relieve at the current average cost so the per-share average is unchanged.
    # Guard against over-selling more than is currently held.
    relieved_qty = [ qty.abs, @total_qty ].min
    @total_cost -= average_cost * relieved_qty
    @total_qty -= relieved_qty

    # Coercing to BigDecimal keeps arithmetic exact, so a full liquidation lands
    # on exactly zero and the reset fires (Float math could leave a tiny remainder).
    reset if @total_qty <= 0
  end

  # Current weighted-average cost per share, or nil when nothing is held.
  def average_cost
    return nil if @total_qty.zero?

    @total_cost / @total_qty
  end

  private
    def reset
      @total_cost = BigDecimal("0")
      @total_qty = BigDecimal("0")
    end
end
