class Provider::ConsentExpiryCheckJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  EXPIRY_WARNING_WINDOW = 7.days

  def perform
    Provider::Connection.where(status: :healthy).find_each do |connection|
      raw = connection.metadata["consent_expires_at"]
      next unless raw.present?

      expiry = Time.zone.parse(raw)
      if expiry <= EXPIRY_WARNING_WINDOW.from_now
        connection.update!(status: :requires_update, sync_error: "consent_expiring")
        Rails.logger.info("[ConsentExpiryCheckJob] Marked connection #{connection.id} as requires_update (expires #{expiry})")
      end
    rescue => e
      Rails.logger.error("[ConsentExpiryCheckJob] Failed to check connection #{connection.id}: #{e.message}")
    end
  end
end
