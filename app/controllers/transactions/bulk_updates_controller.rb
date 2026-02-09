class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    entry_ids = bulk_update_params[:entry_ids]
    entries_scope = Current.family.entries.where(id: entry_ids)
    
    # Bulk update without locking attributes first, so rules can modify them
    updated = entries_scope.bulk_update!(bulk_update_params, update_tags: tags_provided?, lock_attributes: false)

    # Apply rules to all updated transactions (before locking attributes)
    # Rules can modify date, notes, category_id, merchant_id, and tags
    if updated > 0
      updated_entries = entries_scope.includes(:entryable).to_a
      begin
        ApplyRulesToTransactionService.new(updated_entries, execution_type: "manual").call
        # Reload entries after rules may have modified them
        updated_entries.each(&:reload)
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
        # Reload entries even if rules failed
        updated_entries.each(&:reload)
        # Continue execution - don't fail the bulk update response
      end
      
      # Now lock attributes and mark as user modified after rules have been applied
      entries_scope.find_each do |entry|
        entry.lock_saved_attributes!
        entry.mark_user_modified!
        entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
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
