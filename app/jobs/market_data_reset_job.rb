# Instance-wide counterpart to DataCacheClearJob, reserved for super admins.
#
# Exchange rates and security prices are shared by every family, so after
# deleting them we re-import everything the instance needs before any family
# syncs. Otherwise parallel account syncs race to re-import the same pairs and
# other families see unconverted (1:1) totals until the next scheduled import.
class MarketDataResetJob < ApplicationJob
  queue_as :scheduled
  # A retry would delete the freshly re-imported data again.
  sidekiq_options lock: :until_executed, on_conflict: :log, retry: false

  def perform
    ActiveRecord::Base.transaction do
      # Only delete what a configured provider can fetch again; anything else
      # would be lost for good.
      ExchangeRate.delete_all if exchange_rate_provider?
      Security::Price.where(security_id: refetchable_securities.select(:id)).delete_all
    end

    importer = MarketDataImporter.new(mode: :full)
    # Import each kind on its own so a failure in one still leaves the other in
    # place before the family syncs start.
    import_step(:security_prices) { importer.import_security_prices }
    import_step(:exchange_rates) { importer.import_exchange_rates }

    SyncAllJob.perform_later
  end

  private
    def exchange_rate_provider?
      ExchangeRate.provider.present?
    rescue Provider::Registry::Error
      false
    end

    # Mirrors Security#price_data_provider: an assigned provider must still be
    # available, unassigned securities fall back to any enabled provider.
    def refetchable_securities
      available = Setting.enabled_securities_providers.select { |name| Security.provider_for(name) }
      return Security.none if available.empty?

      Security.online.where(price_provider: available).or(Security.online.where(price_provider: nil))
    end

    # A failed import must not stop the family syncs: they fetch any rates and
    # prices that are still missing.
    def import_step(step)
      yield
    rescue => e
      Rails.logger.error("MarketDataResetJob #{step} import failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      DebugLogEntry.capture(
        category: "market_data",
        level: "error",
        message: "Market data re-import after reset failed; continuing with family syncs",
        source: self.class.name,
        metadata: { step: step, error_class: e.class.name }
      )
    end
end
