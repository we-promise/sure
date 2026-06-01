class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    writable_account_ids = Current.family.accounts.writable_by(Current.user).pluck(:id)
    requested_ids = Array(bulk_update_params[:entry_ids]).map(&:to_i)
    # Skip split parents from bulk update - update children instead
    updated = Current.family
                     .entries
                     .excluding_split_parents
                     .where(account_id: writable_account_ids, id: requested_ids)
                     .bulk_update!(bulk_update_params, update_tags: tags_provided?)

    if updated < requested_ids.length
      redirect_back_or_to transactions_path, alert: "Some transactions could not be updated due to permissions"
      return
    end

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
