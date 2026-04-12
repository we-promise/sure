class ExchangeRate::Importer
  MissingExchangeRateError = Class.new(StandardError)
  MissingStartRateError = Class.new(StandardError)

  PROVISIONAL_LOOKBACK_DAYS = 5

  def initialize(exchange_rate_provider:, from:, to:, start_date:, end_date:, clear_cache: false)
    @exchange_rate_provider = exchange_rate_provider
    @from = from
    @to = to
    @start_date = start_date
    @end_date = normalize_end_date(end_date)
    @clear_cache = clear_cache
  end

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

    prev_rate_value = start_rate_value

    # Always find the earliest valid provider rate for pair metadata tracking.
    # record_first_provider_rate_on's atomic guard prevents moving the date forward.
    earliest_valid_provider_date = provider_rates.values
      .select { |r| r.rate.present? && r.rate.to_f > 0 }
      .min_by(&:date)&.date

    # When no anchor rate exists, advance the loop start to the earliest provider rate
    loop_start_date = fill_start_date
    if prev_rate_value.blank? && earliest_valid_provider_date
      earliest_rate = provider_rates[earliest_valid_provider_date]
      Rails.logger.info(
        "#{from}->#{to}: no provider rate on or before #{start_date}; " \
        "advancing gapfill start to earliest valid provider date #{earliest_valid_provider_date}"
      )
      prev_rate_value = earliest_rate.rate
      loop_start_date = earliest_valid_provider_date
    end

    unless prev_rate_value.present?
      error = MissingStartRateError.new("Could not find a start rate for #{from} to #{to} between #{start_date} and #{end_date}")
      Rails.logger.error(error.message)
      Sentry.capture_exception(error)
      return
    end

    # Gapfill with LOCF strategy (last observation carried forward):
    # when the provider returns nothing for weekends/holidays, carry the previous rate.
    gapfilled_rates = loop_start_date.upto(end_date).map do |date|
      db_rate_value = db_rates[date]&.rate
      provider_rate_value = provider_rates[date]&.rate

      chosen_rate = provider_rate_value || db_rate_value

      if chosen_rate.nil? || chosen_rate.to_f <= 0
        chosen_rate = prev_rate_value
      end

      prev_rate_value = chosen_rate

      {
        from_currency: from,
        to_currency: to,
        date: date,
        rate: chosen_rate
      }
    end

    upsert_rows(gapfilled_rates)

    # Compute and upsert inverse rates (e.g., EUR→USD from USD→EUR) to avoid
    # separate API calls for the reverse direction.
    inverse_rates = gapfilled_rates.filter_map do |row|
      next if row[:rate].to_f <= 0

      {
        from_currency: row[:to_currency],
        to_currency: row[:from_currency],
        date: row[:date],
        rate: (BigDecimal("1") / BigDecimal(row[:rate].to_s)).round(12)
      }
    end

    upsert_rows(inverse_rates)

    # Backfill inverse rows for any forward rates that existed in the DB
    # before the loop range (i.e. dates not covered by gapfilled_rates).
    backfill_inverse_rates_if_needed

    if earliest_valid_provider_date.present?
      ExchangeRatePair.record_first_provider_rate_on(
        from: from, to: to, date: earliest_valid_provider_date,
        provider_name: current_provider_name
      )
    end
  end

  private
    attr_reader :exchange_rate_provider, :from, :to, :start_date, :end_date, :clear_cache

    # Resolves the provider name the same way as ExchangeRate::Provided.provider:
    # ENV takes precedence over the DB Setting to stay consistent in env-configured deployments.
    def current_provider_name
      @current_provider_name ||= (ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider).to_s
    end

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

    def start_rate_value
      if fill_start_date == start_date
        provider_rate_value = provider_rates.select { |date, _| date <= start_date }
                                            .max_by { |date, _| date }&.last&.rate
        db_rate_value = db_rates[start_date]&.rate

        return provider_rate_value if provider_rate_value.present? && provider_rate_value.to_f > 0
        return db_rate_value if db_rate_value.present? && db_rate_value.to_f > 0
        return nil
      end

      cutoff_date = fill_start_date

      provider_rate_value = provider_rates
        .select { |date, _| date < cutoff_date }
        .max_by { |date, _| date }&.last&.rate
      return provider_rate_value if provider_rate_value.present? && provider_rate_value.to_f > 0

      ExchangeRate
        .where(from_currency: from, to_currency: to)
        .where("date < ?", cutoff_date)
        .where("rate > 0")
        .order(date: :desc)
        .limit(1)
        .pick(:rate)
    end

    def clamped_start_date
      @clamped_start_date ||= begin
        listed = exchange_rate_pair.first_provider_rate_on
        listed.present? && listed > start_date ? listed : start_date
      end
    end

    def exchange_rate_pair
      @exchange_rate_pair ||= ExchangeRatePair.for_pair(from: from, to: to, provider_name: current_provider_name)
    end

    def fill_start_date
      @fill_start_date ||= [ provider_fetch_start_date, effective_start_date ].max
    end

    def provider_fetch_start_date
      @provider_fetch_start_date ||= begin
        base = effective_start_date - PROVISIONAL_LOOKBACK_DAYS.days
        max_days = exchange_rate_provider.respond_to?(:max_history_days) ? exchange_rate_provider.max_history_days : nil

        if max_days && (end_date - base).to_i > max_days
          clamped = end_date - max_days.days
          Rails.logger.info(
            "#{exchange_rate_provider.class.name} max history is #{max_days} days; " \
            "clamping #{from}->#{to} start_date from #{base} to #{clamped}"
          )
          clamped
        else
          base
        end
      end
    end

    def effective_start_date
      return start_date if clear_cache

      (clamped_start_date..end_date).detect { |d| !db_rates.key?(d) } || end_date
    end

    def provider_rates
      @provider_rates ||= begin
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

    def backfill_inverse_rates_if_needed
      existing_inverse_dates = ExchangeRate.where(from_currency: to, to_currency: from, date: clamped_start_date..end_date).pluck(:date).to_set
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
      (clamped_start_date..end_date).count
    end

    def db_count
      ExchangeRate
        .where(from_currency: from, to_currency: to, date: clamped_start_date..end_date)
        .count
    end

    def db_rates
      @db_rates ||= ExchangeRate.where(from_currency: from, to_currency: to, date: start_date..end_date)
                  .order(:date)
                  .to_a
                  .index_by(&:date)
    end

    # Normalizes an end date so that it never exceeds today's date in the
    # America/New_York timezone.
    def normalize_end_date(requested_end_date)
      today_est = Date.current.in_time_zone("America/New_York").to_date
      [ requested_end_date, today_est ].min
    end
end
