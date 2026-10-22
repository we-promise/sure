class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only allow deletion from accounts where user has owner or full_control permission
    writable_account_ids = writable_accounts.pluck(:id)
    entries_scope = Current.family.entries
                      .where(account_id: writable_account_ids)
                      .where(parent_entry_id: nil)
    selected = entries_scope.where(id: bulk_delete_params[:entry_ids])

    # A purchase owned by an installment plan is locked: deleting it would
    # make the plan disagree with the schedule that replaced it. Leave it
    # alone and tell the user why, instead of reporting it as deleted.
    locked = selected.select(&:installment_plan_locked?)
    deletable = selected - locked

    destroyed = []
    deletable.each do |entry|
      entry.destroy
      destroyed << entry if entry.destroyed?
    end
    destroyed.map(&:account).uniq.each(&:sync_later)

    if locked.any? && destroyed.empty?
      redirect_back_or_to transactions_url,
        alert: "#{locked.count} transaction#{locked.count == 1 ? "" : "s"} could not be deleted because an installment plan owns them"
    elsif locked.any?
      redirect_back_or_to transactions_url,
        alert: "#{destroyed.count} deleted; #{locked.count} could not be deleted because an installment plan owns them"
    else
      redirect_back_or_to transactions_url,
        notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
    end
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    def writable_accounts
      Current.family.accounts.writable_by(Current.user)
    end
end
