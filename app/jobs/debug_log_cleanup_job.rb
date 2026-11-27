# frozen_string_literal: true

class DebugLogCleanupJob < ApplicationJob
  queue_as :scheduled

  def perform
    deleted_count = DebugLogEntry.where(created_at: ...retention_period.ago).delete_all
    Rails.logger.info("DebugLogCleanupJob: Deleted #{deleted_count} debug log entries older than #{retention_period.inspect}") if deleted_count > 0
  end

  private
    def retention_period
      Rails.application.config.x.debug_log.retention_days.days
    end
end
