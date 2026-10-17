class FinecoPortfolioSyncJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    return unless Setting.auto_sync_enabled

    FinecoItem.syncable.includes(:owner, :family).find_each do |item|
      next unless item.syncable? && item.owner&.active?

      item.sync_later
    rescue StandardError
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Fineco portfolio sync could not be scheduled.",
        source: "fineco",
        provider_key: "fineco",
        family: item.family,
        metadata: { fineco_item_id: item.id }
      )
    end
  end
end
