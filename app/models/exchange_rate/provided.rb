module ExchangeRate::Provided
  extend ActiveSupport::Concern

  class_methods do
    def provider
      provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
      registry = Provider::Registry.for_concept(:exchange_rates)
      registry.get_provider(provider.to_sym)
    end

    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      rate = find_by(from_currency: from, to_currency: to, date: date)
      return rate if rate.present?

      return nil unless provider.present? # No provider configured (some self-hosted apps)

      response = provider.fetch_exchange_rate(from: from, to: to, date: date)

      return nil unless response.success? # Provider error

      rate = response.data
      begin
        ExchangeRate.find_or_create_by!(
          from_currency: rate.from,
          to_currency: rate.to,
          date: rate.date
        ) do |exchange_rate|
          exchange_rate.rate = rate.rate
        end if cache
      rescue ActiveRecord::RecordNotUnique
        # Race condition: another process inserted between our SELECT and INSERT
        # Retry by finding the existing record
        ExchangeRate.find_by!(
          from_currency: rate.from,
          to_currency: rate.to,
          date: rate.date
        ) if cache
      end
      rate
    end

    # @return [Integer] The number of exchange rates synced
    def import_provider_rates(from:, to:, start_date:, end_date:, clear_cache: false)
      unless provider.present?
        Rails.logger.warn("No provider configured for ExchangeRate.import_provider_rates")
        return 0
      end

      ExchangeRate::Importer.new(
        exchange_rate_provider: provider,
        from: from,
        to: to,
        start_date: start_date,
        end_date: end_date,
        clear_cache: clear_cache
      ).import_provider_rates
    end
  end
end
