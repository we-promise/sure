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
    locked = selected.where(id: Entry.installment_plan_locked_source_ids)
    deletable = selected.where.not(id: locked.select(:id))
    locked_count = locked.count

    destroyed = []
    deletable.each do |entry|
      entry.destroy
      destroyed << entry if entry.destroyed?
    end
    destroyed.map(&:account).uniq.each(&:sync_later)

    if locked_count.positive? && destroyed.empty?
      redirect_back_or_to transactions_url,
        alert: t("transactions.bulk_deletions.locked", count: locked_count)
    elsif locked_count.positive?
      redirect_back_or_to transactions_url,
        alert: t("transactions.bulk_deletions.partial", destroyed: destroyed.count, count: locked_count)
    else
      redirect_back_or_to transactions_url,
        notice: t("transactions.bulk_deletions.deleted", count: destroyed.count)
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
