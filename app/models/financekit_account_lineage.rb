class FinancekitAccountLineage < ApplicationRecord
  belongs_to :family
  belongs_to :account, optional: true
  has_many :financekit_accounts, dependent: :restrict_with_error
  has_many :financekit_transactions, dependent: :destroy
  has_many :financekit_balance_observations, dependent: :destroy
  has_one :account_provider, as: :provider, dependent: :destroy

  # A publisher credential covers every account in its connection. Fence its
  # queued uploads before releasing links, retaining identities for re-enrollment.
  def disconnect!
    family.with_lock do
      family.financekit_items.where(id: financekit_accounts.select(:financekit_item_id))
        .where.not(status: "revoked").order(:id).each(&:disconnect!)
    end
  end
end
