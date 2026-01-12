class SyncAllJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("Starting sync for all families")
    Family.find_each do |family|
      family.sync_later
    rescue => e
      Rails.logger.error("Failed to sync family #{family.id}: #{e.message}")
    end
    Rails.logger.info("Completed sync for all families")
  end
end
