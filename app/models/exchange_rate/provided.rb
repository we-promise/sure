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
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Race condition: another process inserted between our SELECT and INSERT.
        # RecordNotUnique = DB unique constraint; RecordInvalid = model uniqueness
        # validation fired before the DB got a chance to reject it. Both are safe
        # to handle by reading back the record that the other process just saved.
        return ExchangeRate.find_by!(
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
      unique_currencies = currencies.uniq
      return {} if unique_currencies.empty?

      # Batch-load exact-date matches in a single query
      exact_rates = where(from_currency: unique_currencies, to_currency: to, date: date)
                      .index_by(&:from_currency)

      missing = unique_currencies - exact_rates.keys

      # For currencies without an exact match, batch-load the nearest recent rate
      nearest_rates = if missing.any?
        where(from_currency: missing, to_currency: to)
          .where(date: (date - NEAREST_RATE_LOOKBACK_DAYS)..date)
          .order(date: :desc)
          .to_a
          .each_with_object({}) do |r, map|
            map[r.from_currency] ||= r  # keep most-recent (first due to ORDER BY date DESC)
          end
      else
        {}
      end

      still_missing = missing - nearest_rates.keys

      # Only hit the provider for currencies with no cached rate at all
      fetched_rates = still_missing.each_with_object({}) do |currency, map|
        rate = find_or_fetch_rate(from: currency, to: to, date: date)
        map[currency] = rate if rate
      end

      unique_currencies.each_with_object({}) do |currency, result|
        rate = exact_rates[currency] || nearest_rates[currency] || fetched_rates[currency]
        if rate.nil?
          Rails.logger.warn("No exchange rate found for #{currency}/#{to} on #{date}, using 1")
        elsif rate.date != date
          Rails.logger.debug("FX rate #{currency}/#{to}: using #{rate.date} for #{date} (gap=#{(date - rate.date).to_i}d)")
        end
        result[currency] = rate&.rate || 1
      end
    end

    # @return [Integer] The number of exchange rates synced
    def import_provider_rates(from:, to:, start_date:, end_date:, clear_cache: false, account: nil)
      unless provider.present?
        Rails.logger.warn("No provider configured for ExchangeRate.import_provider_rates")
        return 0
      end

      build_importer = -> {
        ExchangeRate::Importer.new(
          exchange_rate_provider: provider,
          from: from,
          to: to,
          start_date: start_date,
          end_date: end_date,
          clear_cache: clear_cache
        )
      }
      importer = build_importer.call
      return importer.import_provider_rates if importer.rates_up_to_date?

      # Concurrent syncs that need the same currency pair queue up behind one
      # another instead of skipping: a sync that returned without rates would
      # materialize its balances without them. Once the first import is done the
      # next one finds the rates in place and returns without calling the provider.
      # A fresh importer re-reads what the import it waited for stored.
      with_import_lock(from, to, start_date, account) { build_importer.call.import_provider_rates }
    end

    def import_lock_key(from, to)
      Digest::MD5.hexdigest("exchange_rate_import:#{from}:#{to}").to_i(16) % (2**62)
    end

    private
      # Covers a typical import including provider throttling; only a worst-case
      # TwelveData rate-limit retry (~3 minutes) runs longer. Bounded so a sync
      # worker is never held indefinitely.
      IMPORT_LOCK_WAIT_SECONDS = 120
      IMPORT_LOCK_POLL_SECONDS = 1

      # Session-level Postgres advisory lock per pair. Postgres releases it when
      # the connection closes, so a crashed worker cannot leave the pair locked.
      # After the wait the import runs anyway: its rows are upserts, so an
      # overlapping import costs a provider call but never duplicates data.
      def with_import_lock(from, to, start_date, account)
        # The unlock must run on the session that took the lock.
        connection = lease_connection
        key = import_lock_key(from, to)
        acquired = try_import_lock(connection, key)

        attempts = IMPORT_LOCK_WAIT_SECONDS / IMPORT_LOCK_POLL_SECONDS
        until acquired || attempts.zero?
          sleep IMPORT_LOCK_POLL_SECONDS
          attempts -= 1
          acquired = try_import_lock(connection, key)
        end

        unless acquired
          DebugLogEntry.capture(
            category: "exchange_rate_import",
            level: "warn",
            message: "Exchange rate import still locked after #{IMPORT_LOCK_WAIT_SECONDS}s, importing anyway",
            source: name,
            account: account,
            provider_key: ExchangeRatePair.resolve_provider_name,
            metadata: { from: from, to: to, start_date: start_date }
          )
        end

        # Inside a caller's transaction a failed statement would abort it and
        # the unlock below could not run; the savepoint keeps it usable.
        if connection.transaction_open?
          transaction(requires_new: true) { yield }
        else
          yield
        end
      ensure
        advisory_lock_query(connection, "pg_advisory_unlock", key) if acquired
      end

      def try_import_lock(connection, key)
        advisory_lock_query(connection, "pg_try_advisory_lock", key)
      end

      # Uncached: jobs run with the query cache on, and a repeated lock call would
      # otherwise be answered from the cache instead of Postgres.
      def advisory_lock_query(connection, function, key)
        connection.uncached { connection.select_value(sanitize_sql_array([ "SELECT #{function}(?)", key ])) }
      end
  end
end
