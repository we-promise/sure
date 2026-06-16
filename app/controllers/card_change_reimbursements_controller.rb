class CardChangeReimbursementsController < ApplicationController
  layout "settings"

  before_action :set_pair, only: %i[confirm dismiss]

  def index
    @candidates = Current.family.card_change_reimbursement_candidates

    transaction_ids = @candidates.flat_map do |candidate|
      [ candidate.original_transaction_id, candidate.outflow_transaction_id, candidate.inflow_transaction_id ]
    end.uniq

    @transactions_by_id = Current.family.transactions
                                 .where(id: transaction_ids)
                                 .includes(:merchant, :category, entry: :account)
                                 .index_by(&:id)
  end

  # Keep the original purchase (T1) untouched; link the new-card charge (T2)
  # and the reimbursement (T3) as a card-change transfer so they net to zero
  # and drop out of spending/income analytics.
  def confirm
    return unless require_account_permission!(@inflow.entry.account, redirect_path: card_change_reimbursements_path)
    return unless require_account_permission!(@outflow.entry.account, redirect_path: card_change_reimbursements_path)

    transfer = Transfer.new(
      inflow_transaction: @inflow,
      outflow_transaction: @outflow,
      status: "confirmed",
      kind: "card_change"
    )

    if save_transfer(transfer)
      transfer.sync_account_later
      redirect_to card_change_reimbursements_path, notice: t(".confirmed")
    else
      redirect_to card_change_reimbursements_path, alert: t(".invalid")
    end
  end

  def dismiss
    RejectedTransfer.find_or_create_by!(
      inflow_transaction_id: @inflow.id,
      outflow_transaction_id: @outflow.id
    )

    redirect_to card_change_reimbursements_path, notice: t(".dismissed")
  end

  private
    def set_pair
      @inflow = Current.family.transactions.find(params[:id])
      @outflow = Current.family.transactions.find(params[:outflow_id])
    end

    def save_transfer(transfer)
      Transfer.transaction do
        transfer.save!
        # Force funds_movement so the pair is excluded from the income statement
        # regardless of account type (loan_payment / investment_contribution are NOT excluded).
        @inflow.update!(kind: "funds_movement")
        @outflow.update!(kind: "funds_movement")
        @inflow.entry.update!(user_modified: true)
        @outflow.entry.update!(user_modified: true)
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end
end
