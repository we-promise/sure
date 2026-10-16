# Interface for automated valuation model (AVM) providers that can look up a
# property record and return both its attributes and an estimated value in a
# single request.
#
# Includers must define:
# - `MAX_REQUESTS_PER_MONTH` (Integer) — the provider's monthly request budget
# - `RateLimitError` (Class)           — provider-scoped rate-limit error class
module Provider::PropertyValuationConcept
  extend ActiveSupport::Concern

  COUNTRY_ALIASES = {
    "US" => %w[US USA],
    "GB" => %w[GB UK GBR]
  }.freeze

  # `external_id` is the provider's own identifier for the property (e.g. a
  # UK UPRN). The range and confidence are optional; not every provider
  # returns them.
  PropertyValuation = Data.define(
    :valuation, :currency, :property_type, :year_built, :area_value, :area_unit,
    :external_id, :valuation_low, :valuation_high, :confidence
  ) do
    def initialize(external_id: nil, valuation_low: nil, valuation_high: nil, confidence: nil, **rest)
      super
    end
  end

  # The provider class for a registered property valuation provider key, for
  # checking its capabilities (country, required fields, refresh interval)
  # without building an instance or needing an API key.
  def self.provider_class(key)
    return nil unless Provider::Registry.for_concept(:property_valuations).provider_keys.map(&:to_s).include?(key.to_s)

    "Provider::#{key.to_s.camelize}".safe_constantize
  end

  # Capabilities are class-level so eligibility can be checked before a
  # provider instance (and its API key) is resolved. Providers override
  # these with `def self.…`.
  class_methods do
    # Currency of the valuations this provider returns.
    def valuation_currency
      "USD"
    end

    # ISO 3166-1 alpha-2 code of the country the provider covers.
    def supported_country
      "US"
    end

    # Whether lookups need the provider's own property identifier (passed as
    # `external_id:`) rather than the address.
    def requires_external_id?
      false
    end

    def required_address_fields
      %i[line1 locality region postal_code]
    end

    # Minimum time between automatic refreshes of the same property.
    def refresh_interval
      1.day
    end

    # Whether a lookup can be made for this address/identifier — checked
    # before spending a request, both when creating a property and when
    # refreshing.
    def lookup_ready?(address, external_id = nil)
      return false if address.nil?
      return false if required_address_fields.any? { |field| address[field].blank? }
      return false if requires_external_id? && external_id.blank?

      country = address[:country].to_s.strip.upcase
      country.blank? || COUNTRY_ALIASES.fetch(supported_country, [ supported_country ]).include?(country)
    end
  end

  # `external_id:` is only passed to providers that `requires_external_id?`.
  def fetch_property_valuation(line1:, locality: nil, region: nil, postal_code: nil, external_id: nil)
    raise NotImplementedError, "Subclasses must implement #fetch_property_valuation"
  end

  # The refresh job checks this against the account currency before
  # spending a request.
  def valuation_currency
    self.class.valuation_currency
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
    # Defaults to the provider's free tier cap; users on paid plans can raise
    # it via ENV (e.g. RENTCAST_MAX_REQUESTS_PER_MONTH), mirroring the
    # AlphaVantage/Tiingo request limit overrides.
    def max_requests_per_month
      ENV.fetch("#{self.class.name.demodulize.underscore.upcase}_MAX_REQUESTS_PER_MONTH", self.class::MAX_REQUESTS_PER_MONTH).to_i
    end

    def monthly_request_count
      ProviderRequestCount.count_for(provider_key)
    end

    # Counts every outbound request (user-initiated lookups and daily
    # refreshes) against the provider's monthly budget. Backed by a durable
    # database counter (not Rails.cache) so the hard cap can't be reset by
    # cache eviction or a restart.
    def record_monthly_request!
      count = ProviderRequestCount.increment!(provider_key)

      if count > max_requests_per_month
        ProviderRequestCount.decrement!(provider_key)
        raise self.class::RateLimitError.new("#{self.class.name.demodulize} monthly request limit reached (#{max_requests_per_month} per month)")
      end
    end

    def provider_key
      self.class.name.demodulize.underscore
    end
end
