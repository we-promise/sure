# frozen_string_literal: true

class DebugLogCleanupJob < ApplicationJob
  queue_as :scheduled

  RETENTION_PERIOD = 90.days

  def perform
    deleted_count = DebugLogEntry.where(created_at: ...RETENTION_PERIOD.ago).delete_all
    Rails.logger.info("DebugLogCleanupJob: Deleted #{deleted_count} debug log entries older than #{RETENTION_PERIOD.inspect}") if deleted_count > 0
  end
end
