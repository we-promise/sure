# Institutions quote some fixed income as a percent of par and some as a
# fraction of it, so quantity * institution_price can be 100x the position.
# institution_value is the position's value either way.
module PlaidAccount::Investments::HoldingValue
  def self.position_value(quantity:, institution_price:, institution_value:)
    if institution_value&.nonzero? && quantity.nonzero?
      institution_value
    else
      quantity * institution_price
    end
  end
end
