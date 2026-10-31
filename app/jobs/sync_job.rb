class SyncJob < ApplicationJob
  queue_as :high_priority

  # Accept a runtime-only flag to influence sync behavior without persisting config
  def perform(sync, balances_only: false)
    # Attach a transient predicate for this execution only
    begin
      sync.define_singleton_method(:balances_only?) { balances_only }
    rescue => e
      Rails.logger.warn("SyncJob: failed to attach balances_only? flag: #{e.class} - #{e.message}")
    end

    Time.use_zone(family_zone(sync.syncable) || Time.zone) { sync.perform }
  end

  private
    # A cash-anchored account dates its ledger in the family's zone, like the
    # request that created its anchor. Other syncs keep the app zone.
    def family_zone(syncable)
      Time.find_zone(syncable.family.timezone) if syncable.is_a?(Account) && syncable.accounting_start_date
    end
end
