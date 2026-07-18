# Refreshes the valuation of properties linked to an AVM provider.
#
# Runs once per day (see config/schedule.yml) — never hourly — because the
# provider budgets are tight monthly caps (RentCast 50/month, Realie
# 25/month). Each provider additionally enforces its cap via a monthly
# request counter, so refreshes stop once the month's budget is spent.
class SyncPropertyValuationsJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    registry = Provider::Registry.for_concept(:property_valuations)

    Property.where.not(avm_provider: nil).includes(:address).find_each do |property|
      account = property.account
      next unless account&.active?
      next if property.avm_last_synced_on == Date.current

      provider = begin
        registry.get_provider(property.avm_provider)
      rescue Provider::Registry::Error
        nil
      end
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
        account.set_current_balance(response.data.valuation)
        property.update!(avm_last_synced_on: Date.current)
      else
        Rails.logger.warn("SyncPropertyValuationsJob: #{property.avm_provider} refresh failed for property #{property.id}: #{response.error.message}")
      end
    rescue => e
      Rails.logger.error("SyncPropertyValuationsJob: error refreshing property #{property.id}: #{e.message}")
    end
  end
end
