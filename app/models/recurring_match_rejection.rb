# A (series, entry) pair the user rejected: the matcher must never suggest it
# again. Corrections are permanently sticky.
class RecurringMatchRejection < ApplicationRecord
  belongs_to :recurring_transaction
  belongs_to :entry
end
