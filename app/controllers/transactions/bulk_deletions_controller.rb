class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
    changed_accounts = accounts_changed_by_transfer_removal(entries_scope)
    blocked_ids = changed_accounts.filter_map { |entry_id, accounts| entry_id if accounts.any? { |account| !writable_account_ids.include?(account.id) } }
    destroyed = entries_scope.where.not(id: blocked_ids).destroy_by(id: bulk_delete_params[:entry_ids])
    (destroyed.map(&:account) + destroyed.flat_map { |entry| changed_accounts[entry.id] }).uniq.each(&:sync_later)
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    # Deleting a transfer leg (or a split whose child is one) removes the
    # transfer, its fee transactions and, on a counterpart that counts
    # transfers, the balance it moved. Returns those accounts by entry id;
    # entries touching an account the user cannot write are skipped.
    def accounts_changed_by_transfer_removal(scope)
      scope.where(id: bulk_delete_params[:entry_ids], entryable_type: "Transaction")
           .includes(:entryable, child_entries: :entryable)
           .to_h { |entry| [ entry.id, entry.accounts_changed_by_transfer_removal ] }
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
