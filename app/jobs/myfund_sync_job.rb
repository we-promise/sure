class MyfundSyncJob < ApplicationJob
  queue_as :scheduled

  def perform
    MyfundItem.active.find_each do |myfund_item|
      next unless myfund_item.credentials_configured?

      myfund_item.sync_later
    rescue => e
      Rails.logger.error("MyfundSyncJob: Failed to schedule sync for MyfundItem #{myfund_item.id}: #{e.message}")
    end
  end
end
