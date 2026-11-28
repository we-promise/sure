class SyncAllProvidersJob < ApplicationJob
  queue_as :high_priority

  def perform(family_id)
    family = Family.find_by(id: family_id)
    return unless family

    family.request_plaid_transactions_refreshes_later(source: self.class.name)
    family.sync_later
  end
end
