# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # The per-share figures the user locked on this account's holdings, by
    # security and date, in the account's currency as the trackers count.
    # Each is the basis of the units held at the end of its date, so the
    # calculators open the position at it there and roll later trades forward
    # from it. Rows a lock was only carried onto (cost_basis_carried) are not
    # the user's statement, so they are left out. A figure with no rate for
    # its day is left out too, rather than read as the account's currency.
    def manual_cost_bases
      @manual_cost_bases ||= begin
        scope = account.holdings.where(cost_basis_locked: true, cost_basis_carried: false).where.not(cost_basis: nil)
        scope = scope.where(security_id: @security_ids) if @security_ids
        scope.order(Arel.sql("holdings.currency = #{ActiveRecord::Base.connection.quote(account.currency)}"))
          .pluck(:security_id, :date, :cost_basis, :currency)
          .each_with_object(Hash.new { |h, k| h[k] = {} }) do |(security_id, date, cost, currency), bases|
            converted = currency == account.currency ? cost : manual_cost_in_account_currency(cost, currency, date)
            bases[security_id][date] = converted if converted
          end
      end
    end

    def manual_cost_in_account_currency(cost, currency, date)
      Money.new(cost, currency).exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      nil
    end

    # Converts a trade's price into the account's currency at the rate of the
    # day it was made, or nil when there is no rate for that day.
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
      return nil if price.nil? || fee.nil?
      return price if fee.zero?

      price + (fee / trade.qty)
    end

    # The rate on the trade's own day: a basis is what was paid then, and must
    # not drift with the exchange rate afterwards. A rate the trade carries
    # itself (`extra["exchange_rate"]`, e.g. IBKR's fx_rate_to_base) comes
    # first, as it does for the cash balance in Balance::SyncCache. No rate means
    # the amount in the account's currency is unknown -- not the raw figure,
    # which is what a rate of 1.0 would give -- the same answer
    # Trade#calculate_realized_gain_loss gives.
    def convert_to_account_currency(amount, trade, date:)
      Money.new(amount, trade.currency)
        .exchange_to(account.currency, date: date, custom_rate: trade.exchange_rate)
        .amount
    rescue Money::ConversionError
      nil
    end
end
