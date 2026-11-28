class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
    kept = []
    vest_parts = []
    destroyed = entries_scope.where(id: bulk_delete_params[:entry_ids]).filter_map do |entry|
      entry.destroy_unless_split_part_transferred!
    rescue Entry::SplitPartTransferredError
      kept << entry
      nil
    rescue Entry::VestPartDeletionError
      vest_parts << entry
      nil
    end
    destroyed.map(&:account).uniq.each(&:sync_later)

    alerts = []
    alerts << t(".part_transferred", count: kept.size) if kept.any?
    alerts << t(".vest_part", count: vest_parts.size) if vest_parts.any?
    flash[:alert] = alerts.join(" ") if alerts.any?
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
