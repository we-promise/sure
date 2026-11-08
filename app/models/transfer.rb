class Transfer < ApplicationRecord
  belongs_to :inflow_transaction, class_name: "Transaction", inverse_of: :transfer_as_inflow
  belongs_to :outflow_transaction, class_name: "Transaction", inverse_of: :transfer_as_outflow

  has_many :fee_transactions, class_name: "Transaction", dependent: :destroy

  attr_accessor :source_fee_amount, :destination_fee_amount, :tag_ids

  enum :status, { pending: "pending", confirmed: "confirmed" }

  validates :inflow_transaction_id, uniqueness: true
  validates :outflow_transaction_id, uniqueness: true

  validate :transfer_has_different_accounts
  validate :transfer_has_opposite_amounts
  validate :transfer_within_date_range
  validate :transfer_has_same_family

  # Runs on every destroy, including the cascade when one leg's transaction
  # (or its entry) is deleted, so the surviving leg never keeps a transfer kind
  # without a transfer.
  before_destroy :release_transactions

  class << self
    # The outflow leg's kind for a transfer into this account. Transfer::Creator,
    # Family::DataImporter, auto-matching, rules and manual matches all call
    # it (the inflow leg is always funds_movement, see kind_for_leg).
    # from_account: an investment/crypto destination only counts as a
    # contribution when the source isn't itself an investment/crypto account,
    # otherwise it's a plain funds movement.
    def kind_for_account(account, from_account: nil)
      if account.loan?
        "loan_payment"
      elsif account.credit_card?
        "cc_payment"
      elsif account.investment? || account.crypto?
        if from_account && (from_account.investment? || from_account.crypto?)
          "funds_movement"
        else
          "investment_contribution"
        end
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

  # The kind a leg carries while this transfer exists: the outflow by the
  # destination account (unless the user chose whether it is an investment
  # contribution), the inflow always funds_movement.
  def kind_for_leg(transaction)
    return "funds_movement" if transaction.id == inflow_transaction_id
    return transaction.kind if investment_contribution_chosen?(transaction)

    Transfer.kind_for_account(to_account, from_account: from_account)
  end

  # A transfer into an investment or crypto account counts as an investment
  # contribution (a budgeted expense) by default. A user can make it a plain
  # transfer instead, e.g. when a brokerage or crypto account only converts
  # money into another currency.
  def investment_contribution_switchable?
    confirmed? && contribution_by_default?
  end

  def investment_contribution?
    kind_for_leg(outflow_transaction) == "investment_contribution"
  end
  alias_method :investment_contribution, :investment_contribution?

  # The user's explicit choice from update_investment_contribution!, or nil
  # while the transfer follows the default for its destination account.
  def investment_contribution_choice
    investment_contribution? if investment_contribution_chosen?(outflow_transaction)
  end

  # Switches the outflow between investment_contribution and funds_movement
  # and locks the kind, so provider syncs and Transfer::InvestmentKindReconciler
  # keep the choice. The Investment Contributions category follows the switch,
  # since a plain transfer is uncategorized (see
  # Transaction::UNCATEGORIZED_EXCLUDED_KINDS); any other category stays.
  #
  # @return [Boolean] false when this transfer cannot be switched
  def update_investment_contribution!(enabled)
    return false unless investment_contribution_switchable?

    Transfer.transaction do
      # Lock before reading the category, so a concurrent category change is
      # not overwritten by a value derived from a stale read.
      outflow_transaction.lock!

      outflow_attrs = { kind: enabled ? "investment_contribution" : "funds_movement" }
      category = outflow_transaction.category

      if enabled && category.nil?
        outflow_attrs[:category] = to_account.family.investment_contributions_category
      elsif !enabled && category && Category.all_investment_contributions_names.include?(category.name)
        outflow_attrs[:category] = nil
      end

      outflow_transaction.update!(outflow_attrs)
      outflow_transaction.lock_attr!(:kind)
    end

    true
  end

  # Based on the destination account rather than outflow_transaction.kind,
  # which can be stale on rows a provider sync overwrote before
  # Account::ProviderImportAdapter derived matched legs from their transfer
  # (see Transaction#payment?, which has the same to_account-based reasoning).
  def categorizable?
    return false unless to_account

    !Transaction::UNCATEGORIZED_EXCLUDED_KINDS.include?(kind_for_leg(outflow_transaction))
  end

  def reject!
    Transfer.transaction do
      RejectedTransfer.find_or_create_by!(inflow_transaction_id: inflow_transaction_id, outflow_transaction_id: outflow_transaction_id)
      destroy!
    end
  end

  # Auto-matched transfers start out pending and leave both transactions as
  # they were, so an unconfirmed suggestion never moves budgets or reports.
  # The transfer kinds (and the Investment Contributions category) only apply
  # once the user confirms the match.
  def confirm!
    Transfer.transaction do
      update!(status: "confirmed")

      # The kind is determined by the DESTINATION account (inflow), matching Transfer::Creator logic
      outflow_kind = Transfer.kind_for_account(to_account, from_account: from_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution" && outflow_transaction.category_id.blank?
        category = to_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present?
      end

      inflow_transaction.update!(kind: "funds_movement")
      outflow_transaction.update!(outflow_attrs)
    end
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
    def contribution_by_default?
      to_account.present? && Transfer.kind_for_account(to_account, from_account: from_account) == "investment_contribution"
    end

    # The outflow kind update_investment_contribution! set and locked.
    def investment_contribution_chosen?(transaction)
      transaction.locked?(:kind) &&
        %w[investment_contribution funds_movement].include?(transaction.kind) &&
        contribution_by_default?
    end

    # Gives each surviving transaction back its standalone state. When the
    # transfer goes because one leg is being deleted (dependent: :destroy on
    # Transaction), that leg is skipped.
    def release_transactions
      deleted_leg_key = destroyed_by_association&.foreign_key&.to_s

      { "inflow_transaction_id" => inflow_transaction, "outflow_transaction_id" => outflow_transaction }.each do |key, transaction|
        next if transaction.nil? || key == deleted_leg_key
        next unless Transaction.exists?(transaction.id)
        begin
          # A pending auto-match never changed the kind (see #confirm!), so a
          # transfer kind on its transactions predates the match and stays.
          if transaction.transfer? && !pending?
            transaction.update!(kind: "standard")
            # A kind locked by update_investment_contribution! belonged to this transfer.
            transaction.unlock_attr!(:kind) if transaction.locked?(:kind)
          end
          # The entry survives this destroy (only the Transfer join row and
          # fee transactions go away), but its idempotency_key must not: a
          # later retry of the original create request looks up that key,
          # finds no Transfer anymore, and would otherwise hit the unique
          # index on the stale entry and raise instead of creating a new
          # transfer (see Transfer::Creator#find_existing_transfer).
          transaction.entry.update!(idempotency_key: nil) if transaction.entry&.idempotency_key.present?
        rescue ActiveRecord::RecordNotFound
        rescue NoMethodError
          next
        end
      end
    end

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
