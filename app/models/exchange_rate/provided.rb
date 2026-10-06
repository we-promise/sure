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

    # A stored rate of zero or below is skipped, as everywhere else (see
    # #usable_rates), so the provider is still asked; its answer replaces the
    # unusable row rather than leaving it to be skipped on every request.
    def find_or_fetch_rate(from:, to:, date: Date.current, cache: true)
      rate = usable_rates.find_by(from_currency: from, to_currency: to, date: date)
      return rate if rate.present?

      # Reuse the nearest recently-cached rate before hitting the provider.
      # Providers like Yahoo Finance return the most recent trading-day rate
      # (e.g. Friday for a Saturday request) and save it under that date, so
      # subsequent requests for the weekend date always miss the exact lookup
      # and trigger redundant API calls.
      nearest = usable_rates.where(from_currency: from, to_currency: to)
                  .where(date: (date - NEAREST_RATE_LOOKBACK_DAYS)..date)
                  .order(date: :desc)
                  .first
      return nearest if nearest.present?

      return nil unless provider.present? # No provider configured (some self-hosted apps)

      response = provider.fetch_exchange_rate(from: from, to: to, date: date)

      return nil unless response.success? # Provider error

      rate = response.data
      return rate unless cache

      begin
        stored = ExchangeRate.find_or_create_by!(
          from_currency: rate.from,
          to_currency: rate.to,
          date: rate.date
        ) do |exchange_rate|
          exchange_rate.rate = rate.rate
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Race condition: another process inserted between our SELECT and INSERT.
        # RecordNotUnique = DB unique constraint; RecordInvalid = model uniqueness
        # validation fired before the DB got a chance to reject it. Both are safe
        # to handle by reading back the record that the other process just saved,
        # unless what it saved is unusable; then the provider's answer stands.
        stored = ExchangeRate.find_by!(
          from_currency: rate.from,
          to_currency: rate.to,
          date: rate.date
        )
        return stored.rate.to_d.positive? ? stored : rate
      end

      # Replace an unusable row with the provider's answer. Outside the race
      # rescue above, and best-effort: if the write fails, the provider's rate
      # is still the answer, never the row it could not replace.
      if !stored.rate.to_d.positive? && rate.rate.to_d.positive?
        begin
          stored.update!(rate: rate.rate)
        rescue ActiveRecord::ActiveRecordError => e
          Rails.logger.warn("Could not replace unusable exchange rate #{rate.from}/#{rate.to} on #{rate.date}: #{e.message}")
        end
      end
      rate
    end

    # Batch-fetches exchange rates for multiple source currencies.
    # Returns a hash mapping each currency to its numeric rate: the day's,
    # then a recent one, then the provider's, then the latest stored one
    # however old, then the earliest stored one after the day (as the balance
    # chart does). A currency with no stored rate at all is left out rather
    # than given 1: "no rate" and "parity" are different facts, and a caller
    # that cannot tell them apart reports a ¥1,000,000 gain as $1,000,000
    # (#3640). Each caller decides what an absent rate means for its figure.
    #
    # A stored rate of zero or below is no rate: multiplying by it books an
    # amount as nothing, or flips its sign. `to` itself converts at 1.
    def rates_for(currencies, to:, date: Date.current)
      unique_currencies = currencies.uniq - [ to ]
      same = currencies.include?(to) ? { to => 1 } : {}
      return same if unique_currencies.empty?

      # Batch-load exact-date matches in a single query
      exact_rates = usable_rates.where(from_currency: unique_currencies, to_currency: to, date: date)
                      .index_by(&:from_currency)

      missing = unique_currencies - exact_rates.keys

      # For currencies without an exact match, batch-load the nearest recent rate
      nearest_rates = if missing.any?
        usable_rates.where(from_currency: missing, to_currency: to)
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
        map[currency] = rate if rate&.rate.to_d.positive?
      end

      # A rate from any distance is closer to the truth than 1.
      unfetched = still_missing - fetched_rates.keys
      stored_rates = unfetched.any? ? any_stored_rates(unfetched, to: to, date: date) : {}

      unique_currencies.each_with_object(same) do |currency, result|
        rate = exact_rates[currency] || nearest_rates[currency] || fetched_rates[currency] || stored_rates[currency]
        if rate.nil?
          Rails.logger.warn("No exchange rate found for #{currency}/#{to} on #{date}")
          next
        elsif rate.date != date
          Rails.logger.debug("FX rate #{currency}/#{to}: using #{rate.date} for #{date} (gap=#{(date - rate.date).to_i}d)")
        end
        result[currency] = rate.rate
      end
    end

    # SQL for the rate that converts `from` into `to` on `on`, by the same rule
    # as #rates_for without the provider: 1 for the same currency, else the
    # latest stored rate on or before the day, else the earliest after it, else
    # NULL. Amounts multiplied by a NULL rate drop out of a SUM, which is the
    # point: an amount with no rate is left out, never counted at parity.
    #
    # Arguments are SQL expressions, so a caller passes column names or named
    # binds (`:target_currency`), not values.
    def rate_sql(from:, to:, on:)
      <<~SQL.squish
        CASE WHEN #{from} = #{to} THEN 1 ELSE COALESCE(
          (SELECT fx.rate FROM exchange_rates fx
            WHERE fx.from_currency = #{from} AND fx.to_currency = #{to} AND fx.date <= #{on} AND fx.rate > 0
            ORDER BY fx.date DESC LIMIT 1),
          (SELECT fx.rate FROM exchange_rates fx
            WHERE fx.from_currency = #{from} AND fx.to_currency = #{to} AND fx.date > #{on} AND fx.rate > 0
            ORDER BY fx.date ASC LIMIT 1)
        ) END
      SQL
    end

    # The stored rate #rate_sql would use for one pair, without the provider:
    # the latest on or before `date`, else the earliest after it, else nil.
    def nearest_stored_rate(from:, to:, date:)
      return 1 if from == to

      any_stored_rates([ from ], to: to, date: date)[from]&.rate
    end

    # Of `currencies`, those with no stored rate into `to` on any date. #rate_sql
    # leaves these amounts out; #rates_for does too unless the provider
    # supplies a rate.
    def currencies_without_rate(currencies, to:)
      candidates = currencies.compact.uniq - [ to ]
      return [] if candidates.empty?

      candidates - usable_rates.where(from_currency: candidates, to_currency: to).distinct.pluck(:from_currency)
    end

    # Of `currencies`, those whose newest stored rate into `to` is older than
    # the lookback #rates_for treats as current, with that rate's date. Today's
    # figures in them convert at that older rate. A currency with no rate at
    # all is not here; see #currencies_without_rate.
    def stale_rate_dates(currencies, to:, as_of: Date.current)
      candidates = currencies.compact.uniq - [ to ]
      return {} if candidates.empty?

      usable_rates.where(from_currency: candidates, to_currency: to)
        .group(:from_currency)
        .maximum(:date)
        .select { |_, date| date < as_of - NEAREST_RATE_LOOKBACK_DAYS }
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

    private
      # Rows a conversion may use. ExchangeRate validates presence only, so a
      # provider or an import can leave a 0 behind.
      def usable_rates
        where("exchange_rates.rate > 0")
      end

      # The latest stored rate on or before `date` for each currency, else the
      # earliest after it, in two queries.
      def any_stored_rates(currencies, to:, date:)
        before = usable_rates.where(from_currency: currencies, to_currency: to).where("date <= ?", date)
                   .select("DISTINCT ON (from_currency) *").order(:from_currency, date: :desc)
                   .index_by(&:from_currency)
        rest = currencies - before.keys
        return before if rest.empty?

        after = usable_rates.where(from_currency: rest, to_currency: to).where("date > ?", date)
                  .select("DISTINCT ON (from_currency) *").order(:from_currency, :date)
                  .index_by(&:from_currency)
        before.merge(after)
      end
  end
end
