class EnableBankingAccount < ApplicationRecord
  belongs_to :enable_banking_item

  has_one :account, dependent: :destroy

  validates :name, :currency, presence: true
  validates :account_id, presence: true, uniqueness: { scope: :enable_banking_item_id }
  validate :has_balance

  def upsert_enable_banking_snapshot!(account_snapshot)
    assign_attributes(
      account_id: account_snapshot["uid"],
      current_balance: account_snapshot.dig("balances", "current"),
      available_balance: account_snapshot.dig("balances", "available"),
      currency: account_snapshot["currency"],
      name: account_snapshot["name"],
      account_type: account_snapshot["account_type"],
      raw_payload: account_snapshot
    )
    save!
  end

  def upsert_enable_banking_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )
    save!
  end

  private
    def has_balance
      return if current_balance.present? || available_balance.present?
      errors.add(:base, "Enable Banking account must have either current or available balance")
    end
end
