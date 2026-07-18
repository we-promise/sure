# Interface for automated valuation model (AVM) providers that can look up a
# US property record and return both its attributes and an estimated value in
# a single request.
#
# Includers must define:
# - `MAX_REQUESTS_PER_MONTH` (Integer) — the provider's monthly request budget
# - `RateLimitError` (Class)           — provider-scoped rate-limit error class
module Provider::PropertyValuationConcept
  extend ActiveSupport::Concern

  PropertyValuation = Data.define(:valuation, :currency, :property_type, :year_built, :area_value, :area_unit)

  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil)
    raise NotImplementedError, "Subclasses must implement #fetch_property_valuation"
  end

  # Whether the provider still has monthly request budget left. Checked by
  # SyncPropertyValuationsJob before spending a request on a refresh.
  def requests_remaining?
    monthly_request_count < max_requests_per_month
  end

  def usage
    with_provider_response do
      used = monthly_request_count

      Provider::UsageData.new(
        used: used,
        limit: max_requests_per_month,
        utilization: (used.to_f / max_requests_per_month * 100).round(1),
        plan: "Free"
      )
    end
  end

  private
    def max_requests_per_month
      self.class::MAX_REQUESTS_PER_MONTH
    end

    def monthly_request_count
      Rails.cache.read(monthly_request_count_key).to_i
    end

    # Counts every outbound request (user-initiated lookups and daily
    # refreshes) against the provider's monthly budget. Mirrors the Tiingo
    # monthly symbol counter: the key is scoped to the calendar month, so the
    # expiry is just cleanup.
    def record_monthly_request!
      count = Rails.cache.increment(monthly_request_count_key, 1, expires_in: 35.days).to_i

      if count > max_requests_per_month
        Rails.cache.decrement(monthly_request_count_key, 1)
        raise self.class::RateLimitError.new("#{self.class.name.demodulize} monthly request limit reached (#{max_requests_per_month} per month)")
      end
    end

    def monthly_request_count_key
      "#{self.class.name.demodulize.underscore}:avm_request_count:#{Date.current.strftime('%Y-%m')}"
    end
end
