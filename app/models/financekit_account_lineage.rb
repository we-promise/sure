class FinancekitAccountLineage < ApplicationRecord
  belongs_to :family
  belongs_to :account, optional: true
  has_many :financekit_accounts, dependent: :restrict_with_error
  has_many :financekit_transactions, dependent: :destroy
  has_many :financekit_balance_observations, dependent: :destroy
  has_one :account_provider, as: :provider, dependent: :destroy
end
