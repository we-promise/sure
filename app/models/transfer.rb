class Transfer < ApplicationRecord
  belongs_to :inflow_transaction, class_name: "Transaction"
  belongs_to :outflow_transaction, class_name: "Transaction"

  enum :status, { pending: "pending", confirmed: "confirmed" }

  validates :inflow_transaction_id, uniqueness: true
  validates :outflow_transaction_id, uniqueness: true

  validate :transfer_has_different_accounts
  validate :transfer_has_opposite_amounts
  validate :transfer_within_date_range
  validate :transfer_has_same_family

  class << self
    def kind_for_account(account)
      if account.loan?
        "loan_payment"
      elsif account.credit_card?
        "cc_payment"
      elsif account.investment? || account.crypto?
        "investment_contribution"
      elsif account.liability?
        "cc_payment"
      else
        "funds_movement"
      end
    end

    # Links two transactions as a confirmed transfer.
    # Automatically determines inflow/outflow from amounts.
    # Raises ActiveRecord::RecordInvalid if the transfer cannot be saved.
    def link!(txn_a, txn_b)
      inflow_txn, outflow_txn = assign_inflow_outflow(txn_a, txn_b)

      transfer = new(
        inflow_transaction: inflow_txn,
        outflow_transaction: outflow_txn,
        status: "confirmed"
      )

      transaction do
        transfer.save!

        destination_account = transfer.inflow_transaction.entry.account
        outflow_kind = kind_for_account(destination_account)
        outflow_attrs = { kind: outflow_kind }

        if outflow_kind == "investment_contribution"
          category = destination_account.family.investment_contributions_category
          outflow_attrs[:category] = category if category.present? && transfer.outflow_transaction.category_id.blank?
        end

        transfer.outflow_transaction.update!(outflow_attrs)
        transfer.inflow_transaction.update!(kind: "funds_movement")
      end

      transfer.sync_account_later
      transfer
    end

    private

      def assign_inflow_outflow(txn_a, txn_b)
        if txn_a.entry.amount.negative?
          [ txn_a, txn_b ]
        else
          [ txn_b, txn_a ]
        end
      end
  end

  def reject!
    Transfer.transaction do
      RejectedTransfer.find_or_create_by!(inflow_transaction_id: inflow_transaction_id, outflow_transaction_id: outflow_transaction_id)
      destroy!
    end
  end

  # Once transfer is destroyed, we need to mark the denormalized kind fields on the transactions
  def destroy!
    Transfer.transaction do
      inflow_transaction.update!(kind: "standard")
      outflow_transaction.update!(kind: "standard")
      super
    end
  end

  def confirm!
    update!(status: "confirmed")
  end

  def date
    inflow_transaction.entry.date
  end

  def sync_account_later
    inflow_transaction&.entry&.sync_account_later
    outflow_transaction&.entry&.sync_account_later
  end

  def to_account
    inflow_transaction&.entry&.account
  end

  def from_account
    outflow_transaction&.entry&.account
  end

  def amount_abs
    inflow_transaction&.entry&.amount_money&.abs
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

  private
    def transfer_has_different_accounts
      return unless inflow_transaction&.entry && outflow_transaction&.entry
      errors.add(:base, "Must be from different accounts") if to_account == from_account
    end

    def transfer_has_same_family
      return unless inflow_transaction&.entry && outflow_transaction&.entry
      errors.add(:base, "Must be from same family") unless to_account&.family == from_account&.family
    end

    def transfer_has_opposite_amounts
      return unless inflow_transaction&.entry && outflow_transaction&.entry

      inflow_entry = inflow_transaction.entry
      outflow_entry = outflow_transaction.entry

      inflow_amount = inflow_entry.amount
      outflow_amount = outflow_entry.amount

      if inflow_entry.currency == outflow_entry.currency
        # For same currency, amounts must be exactly opposite
        errors.add(:base, "Must have opposite amounts") if inflow_amount + outflow_amount != 0
      else
        # For different currencies, just check the signs are opposite
        errors.add(:base, "Must have opposite amounts") unless inflow_amount.negative? && outflow_amount.positive?
      end
    end

    def transfer_within_date_range
      return unless inflow_transaction&.entry && outflow_transaction&.entry

      date_diff = (inflow_transaction.entry.date - outflow_transaction.entry.date).abs
      max_days = status == "confirmed" ? 30 : 4
      errors.add(:base, "Must be within #{max_days} days") if date_diff > max_days
    end
end