class Transfer < ApplicationRecord
  belongs_to :inflow_transaction, class_name: "Transaction"
  belongs_to :outflow_transaction, class_name: "Transaction"

  has_many :fee_transactions, class_name: "Transaction", dependent: :destroy

  attr_accessor :source_fee_amount, :destination_fee_amount

  enum :status, { pending: "pending", confirmed: "confirmed" }

  validates :inflow_transaction_id, uniqueness: true
  validates :outflow_transaction_id, uniqueness: true

  validate :transfer_has_different_accounts
  validate :transfer_has_opposite_amounts
  validate :transfer_within_date_range
  validate :transfer_has_same_family

  class << self
    # Outflow kind for a transfer into `account`. Mirrors
    # Transfer::Creator#outflow_transaction_kind: money moving between two
    # investment-ish accounts is a funds movement, not a contribution, so pass
    # `source_account` whenever it is known.
    def kind_for_account(account, source_account: nil)
      if account.loan?
        "loan_payment"
      elsif account.credit_card?
        "cc_payment"
      elsif (account.investment? || account.crypto?) && !(source_account&.investment? || source_account&.crypto?)
        "investment_contribution"
      elsif account.liability?
        "cc_payment"
      else
        "funds_movement"
      end
    end
  end

  def has_source_fee?
    derived_source_fee_amount > 0
  end

  def has_destination_fee?
    derived_destination_fee_amount > 0
  end

  def has_fees?
    has_source_fee? || has_destination_fee?
  end

  def total_fee
    derived_source_fee_amount + derived_destination_fee_amount
  end

  def derived_source_fee_amount
    fee_transactions.joins(:entry).where(entries: { account_id: from_account.id }).sum("entries.amount")
  end

  def derived_destination_fee_amount
    fee_transactions.joins(:entry).where(entries: { account_id: to_account.id }).sum("entries.amount")
  end

  def amount_abs
    inflow_transaction&.entry&.amount_money&.abs || Money.new(0, from_account&.currency || "USD")
  end

  def name
    acc = to_account
    if payment?
      acc ? "Payment to #{acc.name}" : "Payment"
    else
      acc ? "Transfer to #{acc.name}" : "Transfer"
    end
  end

  def payment?
    to_account&.liability?
  end

  def loan_payment?
    outflow_transaction&.kind == "loan_payment"
  end

  def liability_payment?
    outflow_transaction&.kind == "cc_payment"
  end

  def regular_transfer?
    outflow_transaction&.kind == "funds_movement"
  end

  def transfer_type
    return "loan_payment" if loan_payment?
    return "liability_payment" if liability_payment?
    "transfer"
  end

  def categorizable?
    to_account&.accountable_type == "Loan"
  end

  def reject!
    Transfer.transaction do
      RejectedTransfer.find_or_create_by!(inflow_transaction_id: inflow_transaction_id, outflow_transaction_id: outflow_transaction_id)
      destroy!
    end
  end

  def destroy!
    Transfer.transaction do
      [ inflow_transaction, outflow_transaction ].each do |transaction|
        next if transaction.nil?
        next unless Transaction.exists?(transaction.id)
        begin
          transaction.update!(kind: "standard")
        rescue ActiveRecord::RecordNotFound
        rescue NoMethodError
          next
        end
      end
      super
    end
  end

  def confirm!
    update!(status: "confirmed")
  end

  def date
    inflow_transaction&.entry&.date
  end

  def sync_account_later
    inflow_transaction&.entry&.sync_account_later
    outflow_transaction&.entry&.sync_account_later
    fee_transactions.each { |t| t.entry&.sync_account_later }
  end

  def to_account
    inflow_transaction&.entry&.account
  end

  def from_account
    outflow_transaction&.entry&.account
  end

  private
    def transfer_has_different_accounts
      return unless inflow_transaction&.entry && outflow_transaction&.entry
      errors.add(:base, :different_accounts) if to_account == from_account
    end

    def transfer_has_same_family
      return unless inflow_transaction&.entry && outflow_transaction&.entry
      errors.add(:base, :same_family) unless to_account&.family == from_account&.family
    end

    def transfer_has_opposite_amounts
      return unless inflow_transaction&.entry && outflow_transaction&.entry

      inflow_entry = inflow_transaction.entry
      outflow_entry = outflow_transaction.entry

      inflow_amount_raw = inflow_entry.amount
      outflow_amount_raw = outflow_entry.amount

      errors.add(:base, :opposite_amounts) unless inflow_amount_raw.negative? && outflow_amount_raw.positive?

      if inflow_entry.currency == outflow_entry.currency
        errors.add(:base, :opposite_amounts) if inflow_amount_raw + outflow_amount_raw != 0
      end
    end

    def transfer_within_date_range
      return unless inflow_transaction&.entry && outflow_transaction&.entry

      date_diff = (inflow_transaction.entry.date - outflow_transaction.entry.date).abs
      max_days = status == "confirmed" ? 30 : 4
      errors.add(:base, :within_days, count: max_days) if date_diff > max_days
    end
end
