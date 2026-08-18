class Transactions::BulkUpdatesController < ApplicationController
  def new
  end

  def create
    requested_ids = Array(bulk_update_params[:entry_ids])
    writable_account_ids = Current.family.accounts.writable_by(Current.user).pluck(:id)
    annotatable_account_ids = Current.family.accounts
      .joins(:account_shares)
      .where(account_shares: { user_id: Current.user.id, permission: "read_write" })
      .pluck(:id)

    scope = Current.family.entries.excluding_split_parents

    updated = scope.where(account_id: writable_account_ids, id: requested_ids)
                   .bulk_update!(bulk_update_params, update_tags: tags_provided?)

    if annotatable_account_ids.any?
      updated += scope.where(account_id: annotatable_account_ids, id: requested_ids)
                      .bulk_update!(annotate_bulk_update_params, update_tags: tags_provided?)
    end

    if updated < requested_ids.length
      redirect_back_or_to transactions_path, alert: t(".permission_error")
      return
    end

    redirect_back_or_to transactions_path, notice: "#{updated} transactions updated"
  end

  private
    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    def annotate_bulk_update_params
      bulk_update_params.slice(:notes, :category_id, :merchant_id, :tag_ids).compact
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't touch tags field".
    def tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end
end
