class FinancekitBalanceObservation < ApplicationRecord
  belongs_to :financekit_account_lineage
  belongs_to :financekit_account, optional: true
end
