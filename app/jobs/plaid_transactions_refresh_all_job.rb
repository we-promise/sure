class PlaidTransactionsRefreshAllJob < ApplicationJob
  queue_as :high_priority

  def perform(family, source:)
    family.plaid_items.syncable.find_each do |plaid_item|
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
