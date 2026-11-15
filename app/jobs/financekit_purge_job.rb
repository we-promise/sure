class FinancekitPurgeJob < ApplicationJob
  # Deleting a year of card history is bulk work, not something a family is
  # waiting on a spinner for. Low priority so it never delays an import.
  queue_as :low_priority

  def perform(item)
    return unless item.purge_pending?

    Financekit::Purge.new(item).perform!
  end
end
