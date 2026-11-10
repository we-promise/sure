class DataCacheClearJob < ApplicationJob
  queue_as :low_priority

  SYNC_RETRY_WAIT = 1.minute

  # Market data is refreshed before anything is deleted: the holdings decide
  # which security prices are needed, and the account syncs must start with
  # the refreshed exchange rates.
  #
  # A sync that is already running would have its freshly written balances
  # deleted, and sync_later would only join it, so the job waits for it.
  def perform(family)
    return retry_later(family) if sync_running?(family)

    Family::MarketDataRefresher.new(family).refresh

    # The family and account locks keep sync_later from starting a sync
    # between the check and the delete
    family.with_lock do
      family.accounts.order(:id).lock.pluck(:id)

      if sync_running?(family)
        retry_later(family)
      else
        Balance.where(account_id: family.accounts.select(:id)).delete_all
        Holding.where(account_id: family.accounts.select(:id)).delete_all

        family.sync_later
        sync_daily_scheduled_items(family)
      end
    end
  end

  private
    def sync_running?(family)
      Sync.visible.where(syncable: family)
        .or(Sync.visible.where(syncable_type: "Account", syncable_id: family.accounts.select(:id)))
        .exists?
    end

    def retry_later(family)
      self.class.set(wait: SYNC_RETRY_WAIT).perform_later(family)
    end

    # The family sync leaves out connections on their own schedule of a day or
    # longer, but their accounts' balances and holdings were just cleared too,
    # so rebuild them now rather than when the schedule next comes due.
    def sync_daily_scheduled_items(family)
      Family::Syncer.syncable_item_associations.each do |association|
        SyncSchedule.with_own_daily_schedule(family.public_send(association).syncable).find_each(&:sync_later)
      end
    end
end
