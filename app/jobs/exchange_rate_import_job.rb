class ExchangeRateImportJob < ApplicationJob
  RateLimitError = Class.new(StandardError)

  retry_on RateLimitError, wait: 2.minutes, attempts: 3

  def perform(from:, to:, start_date:, end_date:, clear_cache: false)
    provider = ExchangeRate.provider

    unless provider.present?
      Rails.logger.warn("No provider configured for ExchangeRateImportJob")
      return
    end

    importer = ExchangeRate::Importer.new(
      exchange_rate_provider: provider,
      from: from,
      to: to,
      start_date: start_date,
      end_date: end_date,
      clear_cache: clear_cache
    )

    result = importer.import_provider_rates

    if result == :rate_limited
      raise RateLimitError, "Rate limit hit for #{from}/#{to}, scheduling retry"
    end
  end
end
