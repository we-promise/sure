class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    # Skip split parents from bulk update - update children instead.
    # Scope to accounts the current user can actually write to — family
    # membership alone isn't enough (e.g. a read_only account share). Entries
    # on accounts the user can't write to are silently excluded from the
    # selection, the same "skip, don't error" posture bulk_update! already
    # uses for reconciled_status on synced accounts.
    updated = Current.family
                     .entries
                     .where(account_id: Account.writable_by(Current.user).select(:id))
                     .excluding_split_parents
                     .where(id: bulk_update_params[:entry_ids])
                     .bulk_update!(bulk_update_params, update_tags: tags_provided?)

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, :reconciled_status, entry_ids: [], tag_ids: [])
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
