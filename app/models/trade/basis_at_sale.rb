# What the units a sale disposed of cost, per unit, when it disposed of them.
#
# A sale's gain is measured against a holding, and a holding is a snapshot of
# the end of a day. That is the basis at the sale for every sale but one kind:
# a sale followed, the same day, by another trade in the security. A purchase
# after it moves the day's average to a price the units sold never cost, and
# one after a sale that closed the position replaces their basis outright.
#
# For that sale, this starts from the snapshot of the day before and applies
# the day's trades up to the sale, in the order the calculators apply them and
# by their rules: a split at the open of its ex-date, a buy at its price plus
# its fee, a sale relieving at the running average, and units moved in at a
# cost nothing here knows, until the position is closed.
class Trade::BasisAtSale
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  # `opening` is the snapshot of the security before the sale's date, if any;
  # `split` the split taking effect on that date, if any; `earlier` the trades
  # in the security on that date before the sale, in order.
  def initialize(trade, opening:, split:, earlier:)
    @account = trade.entry.account
    @opening = opening
    @split = split
    @earlier = earlier
  end

  # Money in the account's currency, or nil when the basis is unknown.
  def average_cost
    tracker = Holding::CostBasisTracker.new
    seed(tracker)

    tracker.split(@split.ratio) if @split

    @earlier.each do |trade|
      price = trade.internal_movement? && trade.qty.positive? ? nil : effective_trade_price(trade, date: trade.entry.date)
      tracker.apply(price, trade.qty)
    end

    cost = tracker.average_cost
    cost && Money.new(cost, account.currency)
  end

  private
    # The opening position at its own basis. Held at an unknown one, it makes
    # the basis unknown until it is closed, as an inbound movement does.
    def seed(tracker)
      return unless @opening&.qty&.positive?

      tracker.buy(@opening.avg_cost&.amount, @opening.qty)
    end
end
