# Re-signs a Sophtron account's stored transactions after its detected sign
# convention changes, then recalculates the linked account's balances.
#
# Runs outside the request that saved the override because it re-imports every
# stored transaction, and it does not wait for an item sync, which skips cards
# marked for manual sync.
class SophtronTransactionsReprocessJob < ApplicationJob
  queue_as :medium_priority

  def perform(sophtron_account)
    return unless sophtron_account.current_account.present?

    SophtronAccount::Transactions::Processor.new(sophtron_account).process
    sophtron_account.current_account.sync_later
  end
end
