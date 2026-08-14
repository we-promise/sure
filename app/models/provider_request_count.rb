# Durable monthly API request counters for providers with hard request
# budgets (e.g. AVM property valuation providers). Stored in the database
# rather than Rails.cache so budget enforcement survives cache eviction,
# restarts, and Redis flushes.
class ProviderRequestCount < ApplicationRecord
  validates :provider_key, :period, presence: true
  validates :provider_key, uniqueness: { scope: :period }

  class << self
    def current_period
      Date.current.strftime("%Y-%m")
    end

    # Atomically increments the counter and returns the new count.
    def increment!(provider_key, period: current_period)
      result = upsert(
        { provider_key: provider_key, period: period, count: 1 },
        unique_by: %i[provider_key period],
        on_duplicate: Arel.sql("count = provider_request_counts.count + 1, updated_at = CURRENT_TIMESTAMP"),
        returning: %w[count]
      )
      result.rows.first.first.to_i
    end

    def decrement!(provider_key, period: current_period)
      where(provider_key: provider_key, period: period).update_all("count = GREATEST(count - 1, 0)")
    end

    def count_for(provider_key, period: current_period)
      where(provider_key: provider_key, period: period).pick(:count).to_i
    end
  end
end
