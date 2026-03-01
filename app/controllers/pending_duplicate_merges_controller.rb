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

    # Validate the posted entry is an eligible candidate (same account, currency, not pending)
    posted_entry = find_eligible_posted_entry(merge_params[:posted_entry_id])
    
    unless posted_entry
      redirect_back_or_to transactions_path, alert: "Invalid transaction selected for merge"
      return
    end

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

    def find_eligible_posted_entry(entry_id)
      # Constrain to same account, currency, and ensure it's a posted transaction
      # Use the same logic as pending_duplicate_candidates to ensure consistency
      conditions = Transaction::PENDING_PROVIDERS.map { |provider| "(transactions.extra -> '#{provider}' ->> 'pending')::boolean IS NOT TRUE" }
      
      @transaction.entry.account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(id: entry_id)
        .where(currency: @transaction.entry.currency)
        .where.not(id: @transaction.entry.id)
        .where(conditions.join(" AND "))
        .first
    end

    def merge_params
      params.require(:pending_duplicate_merges).permit(:posted_entry_id)
    end
end
