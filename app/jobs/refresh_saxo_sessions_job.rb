class RefreshSaxoSessionsJob < ApplicationJob
  queue_as :high_priority
  # Each item can wait on a 30-second OAuth request; a slow run must not
  # overlap the next five-minute tick.
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    SaxoItem.syncable.find_each do |item|
      item.access_token!
    rescue ActiveRecord::RecordNotFound
      next
    rescue Provider::Saxo::Error => error
      # An authorization failure marks the item for reconnection, so it is
      # logged once. Outages and rate limits are retried every tick.
      authorization_failed = error.is_a?(Provider::Saxo::AuthenticationError)
      DebugLogEntry.capture(
        category: authorization_failed ? "provider_auth_error" : "provider_sync_error",
        level: authorization_failed ? "error" : "warn",
        message: error.message,
        source: self.class.name,
        provider_key: "saxo",
        family: item.family,
        metadata: error.diagnostic.merge(saxo_item_id: item.id)
      )
    rescue => error
      Rails.logger.error("Failed to refresh Saxo session #{item.id}: #{error.class}: #{error.message}")
    end
  end
end
