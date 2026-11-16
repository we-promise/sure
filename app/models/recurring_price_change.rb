# One observed price change on a series: previous amount, new amount, when it
# took effect, and the charge that revealed it. The rows are the series' price
# history, feeding subscription intelligence (price sparklines, "raised twice
# this year", annualized deltas).
class RecurringPriceChange < ApplicationRecord
  include Monetizable

  belongs_to :recurring_transaction
  belongs_to :entry, optional: true

  monetize :previous_amount, :new_amount

  enum :source, { detected: "detected", user: "user" }, prefix: :recorded_by

  validates :effective_on, :previous_amount, :new_amount, :currency, presence: true

  # A tenth either way is worth a top notice and a word on the bill's row. A
  # dollar on a ten-dollar subscription is news; a dollar on the rent is not.
  MATERIAL_SHIFT = BigDecimal("0.10")

  # How far the price moved, as a signed fraction of what it was.
  def shift
    previous_amount.to_d.positive? ? (new_amount - previous_amount) / previous_amount : 0
  end

  def material?
    shift.abs >= MATERIAL_SHIFT
  end
end
