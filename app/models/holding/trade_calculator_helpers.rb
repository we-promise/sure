# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # Converts a trade's price into the account's currency at the rate of the
    # day it was made, falling back to the raw price when no rate is available.
    def converted_trade_price(trade, date:)
      convert_to_account_currency(trade.price, trade, date: date)
    end

    # Same, for the fee the trade was charged.
    def converted_trade_fee(trade, date:)
      fee = trade.fee || 0
      return fee if fee.zero?

      convert_to_account_currency(fee, trade, date: date)
    end

    # What the units actually cost, per unit.
    #
    # An acquisition fee is part of the cost of the position, so it belongs in
    # the basis. Providers record it on the trade -- `trades.fee` -- but nothing
    # reads it, so the basis, and every gain derived from it, understates what
    # the purchase cost. The only way to get a fee-inclusive basis today is to
    # fold the fee into `price` by hand, which loses the fee as a separate fact.
    #
    # Only acquisitions are adjusted. The cost-basis tracker relieves a disposal
    # at the running average and never reads its price, so a disposal's fee has
    # no effect on the basis here. That fee belongs on the proceeds side, in
    # Trade#calculate_realized_gain_loss, which does not deduct it yet. A
    # disposal's price is returned unchanged rather than as a fee-adjusted figure
    # that nothing should use.
    def effective_trade_price(trade, date:)
      price = converted_trade_price(trade, date: date)
      return price unless trade.qty&.positive?

      fee = converted_trade_fee(trade, date: date)
      return price if fee.zero?

      price + (fee / trade.qty)
    end

    # The rate on the trade's own day: a basis is what was paid then, and must
    # not drift with the exchange rate afterwards.
    def convert_to_account_currency(amount, trade, date:)
      Money.new(amount, trade.currency).exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      amount
    end
end
