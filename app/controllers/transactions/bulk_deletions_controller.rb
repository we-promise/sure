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
    kept = []
    destroyed = entries_scope.where.not(id: blocked_ids).where(id: bulk_delete_params[:entry_ids]).filter_map do |entry|
      entry.destroy_unless_split_part_transferred!
    rescue Entry::SplitPartTransferredError
      kept << entry
      nil
    end
    (destroyed.map(&:account) + destroyed.flat_map { |entry| changed_accounts.fetch(entry.id, []) }).uniq.each(&:sync_later)

    alerts = []
    alerts << t(".part_transferred", count: kept.size) if kept.any?
    alerts << t(".other_account_not_writable", count: blocked_ids.size) if blocked_ids.any?
    flash[:alert] = alerts.join(" ") if alerts.any?
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    # Deleting a transfer leg removes the transfer, its fee transactions and,
    # on a counterpart that counts transfers, the balance it moved. Returns
    # those accounts by entry id; entries touching an account the user cannot
    # write are skipped.
    def accounts_changed_by_transfer_removal(scope)
      scope.where(id: bulk_delete_params[:entry_ids], entryable_type: "Transaction")
           .includes(:entryable)
           .to_h { |entry| [ entry.id, entry.accounts_changed_by_transfer_removal ] }
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
