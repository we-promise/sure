class IcostPublishJob < ApplicationJob
  queue_as :high_priority
  discard_on ActiveJob::DeserializationError

  def perform(import, user)
    import.process!(user: user)
  rescue StandardError => error
    DebugLogEntry.capture(category: "import", level: "error", source: self.class.name,
      provider_key: "icost", family: import.family, message: "iCost background publication failed",
      metadata: { icost_import_id: import.id, error_class: error.class.name })
    raise
  ensure
    Rails.cache.delete(import.publishing_cache_key)
  end
end
