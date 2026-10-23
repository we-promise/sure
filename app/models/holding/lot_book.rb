# The lots of a single security in one account, built as its trades are applied
# in chronological order.
#
# Every acquisition is one lot, keyed by its source entry, with its own
# quantity, acquisition date and per-unit cost. A transfer-in is a lot whose
# cost nothing here knows. Under the average method a disposal relieves every
# open lot pro rata, so each lot keeps its own cost and only its quantity
# shrinks.
#
# The figure the calculators report, #average_cost, comes from a running pool
# of priced acquisitions rather than from the lots. The two agree, but pro-rata
# lot quantities carry BigDecimal rounding the pool does not, and the pool is
# what every stored figure is computed from. A transfer-in stays outside the
# pool; the calculators report a position holding one as unknown.
#
# Buys add to the running cost and quantity. Sells relieve quantity at the
# current average cost (leaving the per-share average unchanged), and once the
# position is fully closed the pool resets so a later repurchase starts from a
# clean basis. A buy whose price is unknown makes the average unknown until the
# position is fully closed.
#
# Prices are expected in the account's currency (callers convert before
# applying), so the book itself is currency-agnostic.
class Holding::LotBook
  Lot = Data.define(:source_id, :acquired_on, :qty, :unit_cost)

  attr_reader :lots

  def initialize
    @lots = []
    reset
  end

  # Applies a trade by its signed quantity: positive is a buy, negative a sell.
  def apply(price, qty, source_id: nil, acquired_on: nil)
    return if qty.nil?

    qty = qty.to_d
    return if qty.zero?

    qty.positive? ? buy(price, qty, source_id: source_id, acquired_on: acquired_on) : sell(qty)
  end

  def buy(price, qty, source_id: nil, acquired_on: nil)
    qty = qty&.to_d
    return if qty.nil? || !qty.positive?

    add_lot(source_id, acquired_on, qty, price&.to_d)
    @unknown = true if price.nil?
    @total_cost += price.to_d * qty unless price.nil?
    @total_qty += qty
  end

  # Units that arrived by internal movement, at a cost nothing here knows.
  def add_unknown(qty, source_id: nil, acquired_on: nil)
    qty = qty&.to_d
    return if qty.nil? || !qty.positive?

    add_lot(source_id, acquired_on, qty, nil)
  end

  def sell(qty)
    qty = qty&.to_d
    return if qty.nil? || qty.zero?

    relieve_lots(qty.abs)
    return if @total_qty.zero?

    # Relieve at the current average cost so the per-share average is unchanged.
    # Guard against over-selling more than is currently held.
    relieved_qty = [ qty.abs, @total_qty ].min
    @total_cost -= (@total_cost / @total_qty) * relieved_qty
    @total_qty -= relieved_qty

    # Coercing to BigDecimal keeps arithmetic exact, so a full liquidation lands
    # on exactly zero and the reset fires (Float math could leave a tiny remainder).
    reset if @total_qty <= 0
  end

  # A split changes the share count and not the money invested, so total cost
  # stays and the per-share average moves by the inverse of the ratio. Each lot
  # is restated the same way.
  def split(ratio)
    @total_qty = Security::Split.scale(@total_qty, ratio)
    rescale_lots(Security::Split.scale(open_qty, ratio)) do |lot|
      lot.with(
        qty: Security::Split.scale(lot.qty, ratio),
        unit_cost: lot.unit_cost && lot.unit_cost * ratio.denominator / ratio.numerator
      )
    end
  end

  # Current weighted-average cost per share, or nil when nothing is held or
  # the cost of what is held is unknown.
  def average_cost
    return nil if @total_qty.zero? || @unknown

    @total_cost / @total_qty
  end

  def open_qty
    @lots.sum(BigDecimal("0"), &:qty)
  end

  private
    def reset
      @total_cost = BigDecimal("0")
      @total_qty = BigDecimal("0")
      @unknown = false
    end

    def add_lot(source_id, acquired_on, qty, unit_cost)
      @lots << Lot.new(source_id: source_id, acquired_on: acquired_on, qty: qty, unit_cost: unit_cost)
    end

    # Pro-rata relief across every open lot; an oversell closes them all.
    def relieve_lots(qty)
      open = open_qty
      return if open.zero?

      remaining = open - [ qty, open ].min
      rescale_lots(remaining) { |lot| lot.with(qty: lot.qty * remaining / open) }
    end

    # Restates each lot, then gives the last open lot whatever rounding is left,
    # so the lots always sum to exactly `target`.
    def rescale_lots(target)
      scaled = target.zero? ? [] : @lots.map { |lot| yield lot }
      if scaled.any?
        drift = target - scaled.sum(BigDecimal("0"), &:qty)
        scaled[-1] = scaled[-1].with(qty: scaled[-1].qty + drift)
      end
      @lots = scaled.select { |lot| lot.qty.positive? }
    end
end
