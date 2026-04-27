class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
    requested_ids = Array(bulk_delete_params[:entry_ids])
    destroyed = entries_scope.destroy_by(id: requested_ids)
    skipped_count = requested_ids.size - destroyed.count

    destroyed.map(&:account).uniq.each(&:sync_later)

    notice = t("transactions.bulk_deletions.destroy.deleted", count: destroyed.count)
    notice += " #{t("transactions.bulk_deletions.destroy.skipped", count: skipped_count)}" if skipped_count > 0

    redirect_back_or_to transactions_url, notice: notice
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
