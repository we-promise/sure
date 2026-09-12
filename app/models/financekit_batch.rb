class FinancekitBatch < ApplicationRecord
  belongs_to :financekit_item
  belongs_to :sync, optional: true
end
