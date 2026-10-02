class DataCleanerJob < ApplicationJob
  queue_as :scheduled

  def perform
    clean_expired_archived_exports
    clean_stale_enable_banking_psu_ips
  end

  private
    def clean_expired_archived_exports
      deleted_count = ArchivedExport.expired.destroy_all.count

      Rails.logger.info("DataCleanerJob: Deleted #{deleted_count} expired archived exports") if deleted_count > 0
    end

    # Iterated (rather than a single update_all) so each cleared item can be
    # logged with its family attached, making the cleanup visible per-family
    # in /settings/debug instead of only in Docker/Sidekiq logs.
    def clean_stale_enable_banking_psu_ips
      EnableBankingItem.with_stale_psu_ip.find_each do |item|
        item.update!(last_psu_ip: nil)

        DebugLogEntry.capture(
          category: "background_jobs",
          level: "info",
          message: "Cleared stale Enable Banking last_psu_ip",
          source: self.class.name,
          family: item.family,
          metadata: { enable_banking_item_id: item.id }
        )
      end
    end
end
