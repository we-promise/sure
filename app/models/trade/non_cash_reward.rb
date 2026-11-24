class Trade::NonCashReward < Data.define(:quantity, :unit_price)
  PROVIDERS = { "kraken" => KrakenAccount::LedgerProcessor }.freeze

  def self.for(trade)
    return unless trade.qty&.positive? && trade.entry&.amount&.zero?

    source = trade.entry.source
    # Providers return :historical or :unavailable for a reward, and nil for other activity.
    status = PROVIDERS[source]&.reward_price_status(trade.extra[source] || {})
    return unless status

    unit_price = trade.price_money if status == :historical && trade.price&.positive?
    new(quantity: trade.qty, unit_price: unit_price)
  end

  def value
    unit_price * quantity if unit_price
  end
end
