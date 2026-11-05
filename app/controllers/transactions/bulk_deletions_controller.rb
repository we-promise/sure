class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
    entries_scope = entries_scope.where.not(id: entries_moving_unwritable_balances(entries_scope, writable_account_ids))
    destroyed = entries_scope.destroy_by(id: bulk_delete_params[:entry_ids])
    destroyed.map(&:account).uniq.each(&:sync_later)
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    # Deleting a transfer leg removes the transfer, which moves the balance of
    # a counterpart that counts transfers; skip those the user cannot write.
    def entries_moving_unwritable_balances(scope, writable_account_ids)
      scope.where(id: bulk_delete_params[:entry_ids], entryable_type: "Transaction")
           .includes(:entryable)
           .select { |entry| entry.entryable.transfer&.transfer_counting_accounts&.any? { |account| !writable_account_ids.include?(account.id) } }
           .map(&:id)
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
