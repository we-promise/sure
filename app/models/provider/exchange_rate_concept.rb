module Provider::ExchangeRateConcept
  extend ActiveSupport::Concern

  Rate = Data.define(:date, :from, :to, :rate)

  def fetch_exchange_rate(from:, to:, date:)
    raise NotImplementedError, "Subclasses must implement #fetch_exchange_rate"
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    raise NotImplementedError, "Subclasses must implement #fetch_exchange_rates"
  end

  # Maximum number of calendar days of historical FX data the provider can
  # return. Callers should clamp start_date to avoid requesting data beyond
  # this window. Override in subclasses with provider-specific limits.
  def max_history_days
    nil
  end
end
