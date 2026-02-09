class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    entry_ids = bulk_update_params[:entry_ids]
    updated = Current.family
                     .entries
                     .where(id: entry_ids)
                     .bulk_update!(bulk_update_params, update_tags: tags_provided?)

    # Apply rules to all updated transactions
    if updated > 0
      updated_entries = Current.family.entries.where(id: entry_ids).includes(:entryable)
      begin
        ApplyRulesToTransactionService.new(updated_entries.to_a, execution_type: "manual").call
      rescue StandardError => e
        Rails.logger.error("ApplyRulesToTransactionService failed in BulkUpdatesController#create: #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        Rails.logger.error("Context: updated=#{updated}, entry_ids=#{entry_ids.inspect}, entry_count=#{updated_entries.count}")
        # Report to error tracker if available (e.g., Sentry)
        if defined?(Sentry)
          Sentry.capture_exception(e, extra: { 
            updated: updated, 
            entry_ids: entry_ids, 
            entry_count: updated_entries.count,
            family_id: Current.family.id 
          })
        end
        # Continue execution - don't fail the bulk update response
      end
    end

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
