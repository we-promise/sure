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
end
