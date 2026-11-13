# A change in a security's share count that no trade made: a 2-for-1 split
# turns 10 shares into 20 on its ex-date, and a 1-for-10 reverse split turns
# 100 into 10. The money invested does not change, so cost per share moves by
# the inverse of the ratio.
#
# The holding calculators apply it at the open of the ex-date, before that
# day's trades (#249).
class Security::Split < ApplicationRecord
  belongs_to :security

  validates :ex_date, :source, presence: true
  validates :numerator, :denominator, numericality: { only_integer: true, greater_than: 0 }
  validates :ex_date, uniqueness: { scope: :security_id }
  validate :changes_the_share_count

  # New shares per old, exact.
  def ratio
    Rational(numerator, denominator)
  end

  # The scale of the `qty` columns on `holdings` and `trades`. A quantity this
  # code hands around has to be one the database can hold: anything finer is a
  # number no position can actually be in.
  QTY_SCALE = 18

  # A share count after a split of `ratio`, and before it. Multiplying a
  # BigDecimal by a Rational rounds at 32 digits, so 3 shares through a
  # 1-for-3 split came out 0.999...; multiplying by the numerator and then
  # dividing by the denominator is exact whenever the answer is.
  #
  # When the answer doesn't terminate -- 10 shares through a 1-for-3 split is
  # 3.333... -- the result is rounded to the stored scale. Carrying the extra
  # digits instead left a position that had been sold in full holding about
  # 3e-31 of a share: the seller can only sell what the column can hold, so the
  # subtraction missed exact zero, the cost-basis tracker never reset, and an
  # inbound transfer's "cost unknown" mark survived a full liquidation.
  #
  # The cost of rounding here is that scaling and unscaling back can land one
  # unit in the last place away from where it started. That is the floor the
  # column imposes anyway.
  def self.scale(qty, ratio)
    (qty.to_d * ratio.numerator / ratio.denominator).round(QTY_SCALE)
  end

  def self.unscale(qty, ratio)
    (qty.to_d * ratio.denominator / ratio.numerator).round(QTY_SCALE)
  end

  private
    # A 1:1 "split" changes nothing, and the DB refuses it too. Reuses Rails'
    # own `other_than` message, so no new string is needed.
    def changes_the_share_count
      errors.add(:denominator, :other_than, count: numerator) if numerator.present? && numerator == denominator
    end
end
