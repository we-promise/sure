class SyncAllProvidersJob < ApplicationJob
  queue_as :high_priority
  sidekiq_options lock: :until_executed, lock_args: ->(args) { [ args.first ] }, on_conflict: :log

  def perform(family_id)
    family = Family.find_by(id: family_id)
    return unless family

    family.request_plaid_transactions_refreshes_later(source: self.class.name)
    family.sync_later
  end
end
