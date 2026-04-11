class ExchangeRate::Importer
  MissingExchangeRateError = Class.new(StandardError)
  MissingStartRateError = Class.new(StandardError)

  def initialize(exchange_rate_provider:, from:, to:, start_date:, end_date:, clear_cache: false)
    @exchange_rate_provider = exchange_rate_provider
    @from = from
    @to = to
    @start_date = start_date
    @end_date = normalize_end_date(end_date)
    @clear_cache = clear_cache
  end

  # Constructs ExchangeRate records for the given date range and currency pair by fetching
  # We don't need to fill everyday exhange_rate, because when ExhangeRate.find_or_fetch_rate wiill handle it
  def import_provider_rates
    if !clear_cache && all_rates_exist?
      Rails.logger.info("No new rates to sync for #{from} to #{to} between #{start_date} and #{end_date}, skipping")
      backfill_inverse_rates_if_needed
      return
    end

    if provider_rates.empty?
      Rails.logger.warn("Could not fetch rates for #{from} to #{to} between #{start_date} and #{end_date} because provider returned no rates")
      return
    end

    updated_rates = []
    inverse_rates = []

    # Because provider_rates contains -5days data
    filtered_rates = provider_rates.select { |date, _| date >= effective_start_date }
    filtered_rates.each do |date, r|
      rate = r&.rate
      unless rate.present? && rate.to_f > 0
        Rails.logger.warn("Discarding invalid exchange rate for #{from}/#{to} on #{date}")
        next
      end

      updated_rates << {
        from_currency: from,
        to_currency: to,
        date: date,
        rate: rate
      }

      # Compute and upsert inverse rates (e.g., EUR→USD from USD→EUR) to avoid
      # separate API calls for the reverse direction.
      inverse_rates << {
        from_currency: to,
        to_currency: from,
        date: date,
        rate: (BigDecimal("1") / BigDecimal(rate.to_s)).round(12)
      }
    end

    if updated_rates.any?
      upsert_rows(updated_rates)
      upsert_rows(inverse_rates)
      Rails.logger.debug("Upserted #{updated_rates.size} rates for #{from} to #{to} between #{effective_start_date} and #{end_date}")
      if filtered_rates.any?
        Rails.logger.warn("No valid rates to sync for #{from} to #{to} between #{start_date} and #{end_date} after filtering provider response")
      end
    end

    # Also backfill inverse rows for any forward rates that existed in the DB
    # before effective_start_date (i.e. dates not covered by gapfilled_rates).
    backfill_inverse_rates_if_needed
  end

  private
    attr_reader :exchange_rate_provider, :from, :to, :start_date, :end_date, :clear_cache

    def upsert_rows(rows)
      batch_size = 200

      total_upsert_count = 0

      rows.each_slice(batch_size) do |batch|
        upserted_ids = ExchangeRate.upsert_all(
          batch,
          unique_by: %i[from_currency to_currency date],
          returning: [ "id" ]
        )

        total_upsert_count += upserted_ids.count
      end

      total_upsert_count
    end


    # No need to fetch/upsert rates for dates that we already have in the DB
    def effective_start_date
      @effective_start_date ||= begin
        return start_date if clear_cache

        (start_date..end_date).find { |date| !db_rates.key?(date) } || end_date
      end
    end

    def provider_rates
      @provider_rates ||= begin
        # Always fetch with a 5 day buffer to ensure we have a starting rate (for weekends and holidays)
        provider_fetch_start_date = effective_start_date - 5.days

        provider_response = exchange_rate_provider.fetch_exchange_rates(
          from: from,
          to: to,
          start_date: provider_fetch_start_date,
          end_date: end_date
        )

        if provider_response.success?
          Rails.logger.debug("Fetched #{provider_response.data.size} rates from #{exchange_rate_provider.class.name} for #{from}/#{to} between #{provider_fetch_start_date} and #{end_date}")
          provider_response.data.index_by(&:date)
        else
          message = "#{exchange_rate_provider.class.name} could not fetch exchange rate pair from: #{from} to: #{to} between: #{effective_start_date} and: #{Date.current}.  Provider error: #{provider_response.error.message}"
          Rails.logger.warn(message)
          Sentry.capture_exception(MissingExchangeRateError.new(message), level: :warning)
          {}
        end
      end
    end

    # When forward rates already exist but inverse rates are missing (e.g. from a
    # deployment before inverse computation was added), backfill them from the DB
    # without making any provider API calls.
    def backfill_inverse_rates_if_needed
      existing_inverse_dates = ExchangeRate.where(from_currency: to, to_currency: from, date: start_date..end_date).pluck(:date).to_set
      return if existing_inverse_dates.size >= expected_count

      inverse_rows = db_rates.filter_map do |_date, rate|
        next if existing_inverse_dates.include?(rate.date)
        next if rate.rate.to_f <= 0

        {
          from_currency: to,
          to_currency: from,
          date: rate.date,
          rate: (BigDecimal("1") / BigDecimal(rate.rate.to_s)).round(12)
        }
      end

      upsert_rows(inverse_rows) if inverse_rows.any?
    end

    def all_rates_exist?
      db_count == expected_count
    end

    def expected_count
      (start_date..end_date).count
    end

    def db_count
      db_rates.count
    end

    def db_rates
      @db_rates ||= ExchangeRate.where(from_currency: from, to_currency: to, date: start_date..end_date)
                  .order(:date)
                  .to_a
                  .index_by(&:date)
    end

    # Normalizes an end date so that it never exceeds today's date in the
    # America/New_York timezone. If the caller passes a future date we clamp
    # it to today so that upstream provider calls remain valid and predictable.
    def normalize_end_date(requested_end_date)
      today_est = Date.current.in_time_zone("America/New_York").to_date
      [ requested_end_date, today_est ].min
    end
end
