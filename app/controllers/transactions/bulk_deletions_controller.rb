class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
    destroyed = entries_scope.destroy_by(id: bulk_delete_params[:entry_ids])
    destroyed.map(&:account).uniq.each(&:sync_later)
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    # Accounts where the user can delete entries (owner or full_control)
    def writable_accounts
      Current.family.accounts
        .left_joins(:account_shares)
        .where(
          "accounts.owner_id = :uid OR (account_shares.user_id = :uid AND account_shares.permission = :perm)",
          uid: Current.user.id,
          perm: "full_control"
        )
        .distinct
    end
end
