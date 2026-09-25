# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # Converts a trade's price into the account's currency, falling back to the
    # raw price when no exchange rate is available.
    def converted_trade_price(trade)
      Money.new(trade.price, trade.currency).exchange_to(account.currency).amount
    rescue Money::ConversionError
      trade.price
    end

    # Same, for the fee the trade was charged.
    def converted_trade_fee(trade)
      fee = trade.fee || 0
      return fee if fee.zero?

      Money.new(fee, trade.currency).exchange_to(account.currency).amount
    rescue Money::ConversionError
      fee
    end

    # What the units actually cost, per unit.
    #
    # An acquisition fee is part of the cost of the position, so it belongs in
    # the basis. Providers record it on the trade -- `trades.fee` -- but nothing
    # reads it, so the basis, and every gain derived from it, understates what
    # the purchase cost. The only way to get a fee-inclusive basis today is to
    # fold the fee into `price` by hand, which loses the fee as a separate fact.
    #
    # Only acquisitions are adjusted. A disposal is relieved at the running
    # average cost, and its fee reduces the proceeds rather than the basis of
    # whatever remains, so applying it here would understate the units still
    # held.
    def effective_trade_price(trade)
      price = converted_trade_price(trade)
      return price unless trade.qty&.positive?

      fee = converted_trade_fee(trade)
      return price if fee.zero?

      price + (fee / trade.qty)
    end
end
