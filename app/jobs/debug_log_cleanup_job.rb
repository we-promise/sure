# frozen_string_literal: true

class DebugLogCleanupJob < ApplicationJob
  queue_as :scheduled

  def perform
    # A set-aside prompt override is its only copy until the admin saves the prompts page, so it's
    # kept while its family exists; a deleted family's expires with the rest.
    kept = DebugLogEntry.where(category: Family::AiPromptable::DROPPED_CATEGORY).where.not(family_id: nil)
    deleted_count = DebugLogEntry.where(created_at: ...retention_period.ago).where.not(id: kept.select(:id)).delete_all
    Rails.logger.info("DebugLogCleanupJob: Deleted #{deleted_count} debug log entries older than #{retention_period.inspect}") if deleted_count > 0
  end

  private
    def retention_period
      Rails.application.config.x.debug_log.retention_days.days
    end
end
