# Ticks every SyncSchedule::TICK (config/schedule.yml) and syncs the provider
# connections whose own schedule has come due. The daily family sync
# (SyncAllJob) is untouched; this runs in between it.
class SyncScheduledItemsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    SyncSchedule.due.find_each do |schedule|
      # A provider removed from the app leaves rows no validation accepts, so
      # they could never be advanced.
      unless SyncSchedule.schedulable_associations.key?(schedule.syncable_type)
        schedule.destroy!
        next
      end

      # Advanced first, so a connection whose sync keeps failing is retried
      # at its own cadence rather than on every tick. A schedule changed or
      # removed since it was loaded is no longer due.
      next unless schedule.advance!
      item = schedule.syncable

      if item.nil?
        schedule.destroy!
      elsif item.class.syncable.exists?(item.id)
        sync(item)
      end
    rescue => e
      capture_failure(schedule, item, e)
    end
  end

  private
    # Plaid only hands over transactions it has pulled from the bank on its
    # own cadence unless asked to refresh, as every other sync entry point
    # does (its cooldown keeps the requests apart).
    def sync(item)
      if item.respond_to?(:sync_later_with_provider_refresh)
        item.sync_later_with_provider_refresh
      else
        item.sync_later
      end
    end

    def capture_failure(schedule, item, error)
      Rails.logger.error("[SyncScheduledItemsJob] Failed to sync #{schedule.syncable_type} #{schedule.syncable_id}: #{error.message}")

      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Scheduled sync could not be started",
        source: self.class.name,
        provider_key: schedule.syncable_type.to_s.delete_suffix("Item").underscore.presence,
        family: item.try(:family),
        metadata: {
          syncable_type: schedule.syncable_type,
          syncable_id: schedule.syncable_id,
          error_class: error.class.name
        }
      )
    end
end
