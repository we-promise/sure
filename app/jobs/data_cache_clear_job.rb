class DataCacheClearJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    ActiveRecord::Base.transaction do
      ExchangeRate.delete_all
      Security::Price.delete_all
      family.accounts.each do |account|
        account.balances.delete_all
        account.holdings.delete_all
      end

      family.sync_later
      sync_daily_scheduled_items(family)
    end
  end

  private
    # The family sync leaves out connections on their own schedule of a day or
    # longer, but their accounts' balances and holdings were just cleared too.
    # Each is synced again, and its sync rebuilds the accounts once the import
    # is done. A sync already running would be reused and may be past its
    # import, and an older one still unfinished would overlap a new one, so a
    # fresh sync follows any unfinished sync instead.
    def sync_daily_scheduled_items(family)
      Family::Syncer.syncable_item_associations.each do |association|
        SyncSchedule.with_own_daily_schedule(family.public_send(association).syncable).find_each do |item|
          if item.syncs.incomplete.exists?
            FollowUpSyncJob.perform_later(item)
          else
            item.sync_later
          end
        end
      end
    end
end
