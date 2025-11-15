class ClearAiCacheJob < ApplicationJob
  queue_as :low_priority

  def perform
    Rails.logger.info("Clearing AI cache for all transactions and entries")

    # Clear AI cache for all transactions
    Transaction.clear_ai_cache
    Rails.logger.info("Cleared AI cache for transactions")

    # Clear AI cache for all entries
    Entry.clear_ai_cache
    Rails.logger.info("Cleared AI cache for entries")
  end
end
