# Refreshes the valuation of properties linked to an AVM provider.
#
# Runs once per day (see config/schedule.yml) — never hourly — because the
# provider budgets are tight monthly caps (RentCast 50/month, Realie
# 25/month). Each provider additionally enforces its cap via a durable
# monthly request counter, so refreshes stop once the month's budget is spent.
class SyncPropertyValuationsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    registry = Provider::Registry.for_concept(:property_valuations)

    # Stalest valuations first (never-synced before oldest-refreshed) so a
    # tight monthly budget is spent where it matters most, not in
    # primary-key order.
    properties = Property.where.not(avm_provider: nil)
                         .includes(:address, :account)
                         .order(Arel.sql("avm_last_synced_on ASC NULLS FIRST"))

    # One provider instance per key for the whole run — the request throttle
    # tracks its last request time on the instance, so a fresh instance per
    # property would bypass the inter-request delay.
    providers = {}

    properties.each do |property|
      account = property.account
      next unless account&.active?
      next if property.avm_last_synced_on == Date.current

      unless providers.key?(property.avm_provider)
        providers[property.avm_provider] = begin
          registry.get_provider(property.avm_provider)
        rescue Provider::Registry::Error
          nil
        end
      end

      provider = providers[property.avm_provider]
      next unless provider # API key was removed after the property was linked
      next unless provider.requests_remaining?

      address = property.address
      next unless address

      response = provider.fetch_property_valuation(
        line1: address.line1,
        locality: address.locality,
        region: address.region,
        postal_code: address.postal_code
      )

      if response.success?
        result = nil
        Property.transaction do
          result = account.set_current_balance(response.data.valuation)
          raise ActiveRecord::Rollback unless result.success?
          property.update!(avm_last_synced_on: Date.current)
        end

        unless result&.success?
          capture_failure(property, account, "Failed to update valuation balance: #{result&.error}")
        end
      else
        capture_failure(property, account, "Valuation refresh failed: #{response.error.message}")
      end
    rescue => e
      capture_failure(property, property.account, "Error refreshing valuation: #{e.class} - #{e.message}")
    end
  end

  private

    def capture_failure(property, account, message)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: message,
        source: self.class.name,
        provider_key: property.avm_provider,
        account: account,
        metadata: { property_id: property.id }
      )
    end
end
