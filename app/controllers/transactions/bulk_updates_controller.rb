class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    entry_ids = bulk_update_params[:entry_ids]
    updated = Current.family
                     .entries
                     .where(id: entry_ids)
                     .bulk_update!(bulk_update_params)

    # Apply rules to all updated transactions
    if updated > 0
      updated_entries = Current.family.entries.where(id: entry_ids).includes(:entryable)
      ApplyRulesToTransactionService.new(updated_entries.to_a, execution_type: "manual").call
    end

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end
end
