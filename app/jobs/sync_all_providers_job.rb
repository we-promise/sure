class SyncAllProvidersJob < ApplicationJob
  queue_as :high_priority
  sidekiq_options lock: :until_executed, lock_args: ->(args) { [ args.first ] }, on_conflict: :log

  def perform(family_id)
    family = Family.find_by(id: family_id)
    return unless family

    request_plaid_transactions_refreshes(family)
    family.sync_later
  end

  private

    def request_plaid_transactions_refreshes(family)
      family.plaid_items.syncable.find_each do |plaid_item|
        plaid_item.request_transactions_refresh_later
      rescue => error
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "warn",
          message: "Manual provider-wide Plaid transaction refresh could not be enqueued; continuing with normal sync",
          source: self.class.name,
          provider_key: "plaid",
          family: family,
          metadata: { error_class: error.class.name }
        )
      end
    end
end
