class PendingDuplicateMergesController < ApplicationController
  before_action :set_transaction

  def new
    @limit = (params[:limit] || 20).to_i
    @potential_duplicates = @transaction.pending_duplicate_candidates(limit: @limit)
    # Check if there are more transactions available
    @has_more = @transaction.pending_duplicate_candidates(limit: @limit + 1).count > @limit
  end

  def create
    # Manually merge the pending transaction with the selected posted transaction
    unless merge_params[:posted_entry_id].present?
      redirect_back_or_to transactions_path, alert: "Please select a posted transaction to merge with"
      return
    end

    posted_entry = Current.family.entries.find(merge_params[:posted_entry_id])

    # Store the merge suggestion and immediately execute it
    @transaction.update!(
      extra: (@transaction.extra || {}).merge(
        "potential_posted_match" => {
          "entry_id" => posted_entry.id,
          "reason" => "manual_match",
          "posted_amount" => posted_entry.amount.to_s,
          "confidence" => "high",  # Manual matches are high confidence
          "detected_at" => Date.current.to_s
        }
      )
    )

    # Immediately merge
    if @transaction.merge_with_duplicate!
      redirect_back_or_to transactions_path, notice: "Pending transaction merged with posted transaction"
    else
      redirect_back_or_to transactions_path, alert: "Could not merge transactions"
    end
  end

  private
    def set_transaction
      entry = Current.family.entries.find(params[:transaction_id])
      @transaction = entry.entryable

      unless @transaction.is_a?(Transaction) && @transaction.pending?
        redirect_to transactions_path, alert: "This feature is only available for pending transactions"
      end
    end

    def merge_params
      params.require(:pending_duplicate_merges).permit(:posted_entry_id)
    end
end
