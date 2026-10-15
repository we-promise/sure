# Refreshes the valuation of properties linked to an AVM provider.
#
# Scheduled monthly (see config/schedule.yml) because the provider budgets
# are tight monthly caps (RentCast 50/month, Realie 25/month). Each provider
# additionally enforces its cap via a durable monthly request counter, so
# refreshes stop once the month's budget is spent, and sets a minimum
# interval between refreshes of the same property (`refresh_interval`).
#
# Pass `property_id:` with `force: true` for a user-requested refresh of a
# single property, which skips the refresh interval.
class SyncPropertyValuationsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform(property_id: nil, force: false)
    registry = Provider::Registry.for_concept(:property_valuations)

    # Stalest valuations first (never-synced before oldest-refreshed) so a
    # tight monthly budget is spent where it matters most, not in
    # primary-key order.
    properties = Property.where.not(avm_provider: nil)
                         .includes(:address, :account)
                         .order(Arel.sql("avm_last_synced_on ASC NULLS FIRST"))
    properties = properties.where(id: property_id) if property_id.present?

    # One provider instance per key for the whole run — the request throttle
    # tracks its last request time on the instance, so a fresh instance per
    # property would bypass the inter-request delay.
    providers = {}

    # Providers that hit their rate limit during this run; no further
    # requests are sent to them until the next run.
    rate_limited = Set.new

    properties.each do |property|
      account = property.account
      next unless account&.active?
      next if rate_limited.include?(property.avm_provider)

      provider_class = Provider::PropertyValuationConcept.provider_class(property.avm_provider)
      next unless provider_class
      next if !force && recently_synced?(property, provider_class)

      # Skip before spending a monthly-budget request: mirrors the
      # import-time completeness check. A blank city/ZIP would also disable
      # the wrong-city guard in the Realie lookup, letting a refresh accept
      # another property's valuation; ID-based providers (Chimnie) need the
      # property's UPRN. Each provider covers a single country.
      unless provider_class.lookup_ready?(property.address, property.avm_external_id)
        capture_failure(property, account, "Skipping refresh: property address or identifier is incomplete, or the property is outside #{provider_class.supported_country}", level: "warn")
        next
      end

      unless providers.key?(property.avm_provider)
        providers[property.avm_provider] = begin
          registry.get_provider(property.avm_provider)
        rescue Provider::Registry::Error
          nil
        end
      end

      provider = providers[property.avm_provider]
      unless provider # API key was removed after the property was linked
        capture_failure(property, account, "Skipping refresh: #{property.avm_provider} is not configured", level: "warn")
        next
      end
      next unless provider.requests_remaining?

      # The account was created in the provider's currency, but the user can
      # change it later. Writing a USD valuation as another currency would
      # corrupt the balance, so skip mismatches — before spending a request.
      unless account.currency == provider.valuation_currency
        capture_failure(property, account, "Skipping refresh: account currency #{account.currency} does not match provider valuation currency #{provider.valuation_currency}", level: "warn")
        next
      end

      address = property.address
      lookup_params = {
        line1: address.line1,
        locality: address.locality,
        region: address.region,
        postal_code: address.postal_code
      }
      lookup_params[:external_id] = property.avm_external_id if provider_class.requires_external_id?

      response = provider.fetch_property_valuation(**lookup_params)

      if response.success?
        result = nil
        Property.transaction do
          result = account.set_current_balance(response.data.valuation)
          raise ActiveRecord::Rollback unless result.success?
          property.name_avm_valuation!
          property.update!(avm_last_synced_on: Date.current)
        end

        unless result&.success?
          capture_failure(property, account, "Failed to update valuation balance: #{result&.error}")
        end
      else
        rate_limited << property.avm_provider if response.error.is_a?(provider_class::RateLimitError)
        capture_failure(property, account, "Valuation refresh failed: #{response.error.message}")
      end
    rescue => e
      capture_failure(property, property.account, "Error refreshing valuation: #{e.class} - #{e.message}")
    end
  end

  private

    # RentCast and Realie refresh at most daily; Chimnie at most monthly.
    def recently_synced?(property, provider_class)
      property.avm_last_synced_on.present? &&
        property.avm_last_synced_on > Date.current - provider_class.refresh_interval
    end

    def capture_failure(property, account, message, level: "error")
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: level,
        message: message,
        source: self.class.name,
        provider_key: property.avm_provider,
        account: account,
        metadata: { property_id: property.id }
      )
    end
end
