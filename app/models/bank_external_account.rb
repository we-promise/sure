class BankExternalAccount < ApplicationRecord
  belongs_to :bank_connection
  has_one :account, dependent: :nullify

  validates :provider_account_id, presence: true, uniqueness: { scope: :bank_connection_id }

  def upsert_bank_snapshot!(account_data)
    data = account_data.with_indifferent_access

    assign_attributes(
      name: data[:name],
      currency: data[:currency],
      current_balance: data[:current_balance],
      available_balance: data[:available_balance],
      balance_date: Time.current,
      raw_payload: account_data
    )

    save!
  end
end

