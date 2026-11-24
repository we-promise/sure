module TradesHelper
  def format_reward_value(value)
    return t("trades.reward_value.unavailable") unless value
    return format_money(value) unless value.for_display.zero?

    t("trades.reward_value.less_than", amount: format_money(Money.new(value.currency.step, value.currency)))
  end
end
