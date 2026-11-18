class PlaidTransactionsRefreshAllJob < ApplicationJob
  queue_as :high_priority

  # Skips items whose own schedule of a day or longer replaces the family
  # sync: the family sync leaves them out too, and their scheduled sync
  # requests its own refresh.
  def perform(family, source:)
    SyncSchedule.without_own_daily_schedule(family.plaid_items.syncable).find_each do |plaid_item|
      plaid_item.request_transactions_refresh_later
    rescue => error
      capture_warning(family:, source:, error:)
    end
  rescue => error
    capture_warning(family:, source:, error:)
  end

  private
    def capture_warning(family:, source:, error:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Plaid transaction refresh could not be requested; continuing with normal sync",
        source: source,
        provider_key: "plaid",
        family: family,
        metadata: { error_class: error.class.name }
      )
    rescue => logging_error
      Rails.logger.warn(
        "Plaid refresh diagnostic failed: #{logging_error.class.name}"
      )
    end
end
