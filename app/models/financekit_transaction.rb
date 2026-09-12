class FinancekitTransaction < ApplicationRecord
  belongs_to :financekit_account
  belongs_to :entry, optional: true
end
