class RefreshSaxoSessionsJob < ApplicationJob
  queue_as :high_priority

  def perform
    SaxoItem.syncable.find_each do |item|
      item.access_token!
    rescue ActiveRecord::RecordNotFound
      next
    rescue Provider::Saxo::Error => error
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: error.message,
        source: self.class.name,
        provider_key: "saxo",
        family: item.family,
        metadata: { saxo_item_id: item.id }
      )
    end
  end
end
