# Institutions quote some fixed income as a percent of par and some as a
# fraction of it, so quantity * institution_price can be 100x the position.
# institution_value is the position's value either way.
#
# Returns nil when the holding can't be valued, so the holdings import and the
# brokerage cash calculation skip the same holdings.
module PlaidAccount::Investments::HoldingValue
  def self.position_value(quantity:, institution_price:, institution_value:)
    return nil if quantity.nil?
    return institution_value if institution_value&.nonzero? && quantity.nonzero?
    return nil if institution_price.nil?

    quantity * institution_price
  end
end
