class ClearAiCacheJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    if family.nil?
      Rails.logger.warn("ClearAiCacheJob called with nil family, skipping")
      return
    end

    Rails.logger.info("Clearing AI cache for family #{family.id}")

    # Clear AI enrichment data for transactions
    begin
      count = Transaction.clear_ai_cache(family)
      Rails.logger.info("Cleared AI cache for #{count} transactions")
    rescue => e
      Rails.logger.error("Failed to clear AI cache for transactions: #{e.message}")
    end

    # Clear AI enrichment data for entries
    begin
      count = Entry.clear_ai_cache(family)
      Rails.logger.info("Cleared AI cache for #{count} entries")
    rescue => e
      Rails.logger.error("Failed to clear AI cache for entries: #{e.message}")
    end
  end
end
