module TradesHelper
  def format_reward_value(value)
    return t("trades.reward_value.unavailable") unless value
    return format_money(value) unless value.for_display.zero?

    t("trades.reward_value.less_than", amount: format_money(Money.new(value.currency.step, value.currency)))
  end

  def trade_header_gain_loss(trade, current_price)
    return unless current_price
    return if trade.non_cash_reward? && trade.reward_unit_price&.currency != current_price.currency

    trade.unrealized_gain_loss
  end
end
