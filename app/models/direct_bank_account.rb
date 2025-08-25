class DirectBankAccount < ApplicationRecord
  self.abstract_class = true

  belongs_to :direct_bank_connection
  has_one :account, as: :accountable, dependent: :destroy
  has_one :family, through: :direct_bank_connection

  validates :external_id, presence: true
  validates :name, presence: true

  scope :ordered, -> { order(:name) }
  scope :connected, -> { joins(:account) }
  scope :disconnected, -> { left_joins(:account).where(accounts: { id: nil }) }

  def connected?
    account.present?
  end

  def sync_transactions(start_date: nil, end_date: nil)
    return unless connected?

    transactions_data = direct_bank_connection.provider.get_transactions(
      external_id,
      start_date: start_date || 30.days.ago,
      end_date: end_date || Date.current
    )

    process_transactions(transactions_data)
  end

  def sync_balance
    return unless connected?

    balance_data = direct_bank_connection.provider.get_balance(external_id)
    update_balance(balance_data)
  end

  def formatted_balance
    Money.new(current_balance || 0, currency || "USD")
  end

  private

  def process_transactions(transactions_data)
    DirectBank::TransactionProcessor.new(self, transactions_data).process
  end

  def update_balance(balance_data)
    update!(
      current_balance: balance_data[:current],
      available_balance: balance_data[:available],
      balance_date: balance_data[:as_of] || Time.current
    )

    account&.update_balance!(current_balance)
  end
end