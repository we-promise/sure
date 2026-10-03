# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # Converts a trade's price into the account's currency using the exchange
    # rate on the trade's own date. The price is a historical fact denominated on
    # that date, so a foreign-currency trade must not be valued at today's rate --
    # otherwise the cost basis drifts as FX moves. A rate carried on the trade
    # itself (e.g. IBKR's fx-rate-to-base) is preferred over a stored daily rate.
    # Falls back to the raw price when no rate is available, matching
    # Holding::PortfolioCache#get_price.
    def converted_trade_price(trade, date)
      Money.new(trade.price, trade.currency)
           .exchange_to(account.currency, date: date, custom_rate: trade.exchange_rate)
           .amount
    rescue Money::ConversionError
      trade.price
    end
end
