module ExchangeRate::Provided
  extend ActiveSupport::Concern

  class_methods do
    def provider
      provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
      registry = Provider::Registry.for_concept(:exchange_rates)
      registry.get_provider(provider.to_sym)
    end

    # Maximum number of days to look back for a cached rate before calling the provider.
    NEAREST_RATE_LOOKBACK_DAYS = 5

    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      rate = find_by(from_currency: from, to_currency: to, date: date)
      return rate if rate.present?

      # Reuse the nearest recently-cached rate before hitting the provider.
      # Providers like Yahoo Finance return the most recent trading-day rate
      # (e.g. Friday for a Saturday request) and save it under that date, so
      # subsequent requests for the weekend date always miss the exact lookup
      # and trigger redundant API calls.
      nearest = where(from_currency: from, to_currency: to)
                  .where(date: (date - NEAREST_RATE_LOOKBACK_DAYS)..date)
                  .order(date: :desc)
                  .first
      return nearest if nearest.present?

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

    # Batch-fetches exchange rates for multiple source currencies.
    # Returns a hash mapping each currency to its numeric rate, defaulting to 1 when unavailable.
    def rates_for(currencies, to:, date: Date.current)
      currencies.uniq.each_with_object({}) do |currency, map|
        rate = find_or_fetch_rate(from: currency, to: to, date: date)
        if rate.nil?
          Rails.logger.warn("No exchange rate found for #{currency}/#{to} on #{date}, using 1")
        elsif rate.date != date
          Rails.logger.debug("FX rate #{currency}/#{to}: using #{rate.date} for #{date} (gap=#{(date - rate.date).to_i}d)")
        end
        map[currency] = rate&.rate || 1
      end
    end

    # @return [Integer] The number of exchange rates synced
    def import_provider_rates(from:, to:, start_date:, end_date:, clear_cache: false)
      unless provider.present?
        Rails.logger.warn("No provider configured for ExchangeRate.import_provider_rates")
        return 0
      end

      # Prevent concurrent syncs from fetching the same currency pair for overlapping
      # date ranges. The lock is scoped to (pair + start_date) so that a broader range
      # (e.g. daily job needing older history) is not blocked by a narrower account sync.
      #
      # Uses an owner-token pattern: the lock value is a unique token so the ensure
      # block only deletes its own lock, not one acquired by a different worker after
      # expiry. TTL is 5 minutes to cover worst-case throttle + rate-limit retry waits
      # (~3 minutes with TwelveData).
      lock_key = "exchange_rate_import:#{from}:#{to}:#{start_date}"
      lock_token = SecureRandom.uuid
      acquired = Rails.cache.write(lock_key, lock_token, expires_in: 5.minutes, unless_exist: true)

      unless acquired
        Rails.logger.info("Skipping exchange rate import for #{from}/#{to} from #{start_date} — already in progress")
        return 0
      end

      begin
        ExchangeRate::Importer.new(
          exchange_rate_provider: provider,
          from: from,
          to: to,
          start_date: start_date,
          end_date: end_date,
          clear_cache: clear_cache
        ).import_provider_rates
      ensure
        # Only delete the lock if we still own it (it hasn't expired and been
        # re-acquired by another worker).
        Rails.cache.delete(lock_key) if Rails.cache.read(lock_key) == lock_token
      end
    end
  end
end
