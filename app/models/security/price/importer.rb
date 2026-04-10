class Security::Price::Importer
  MissingSecurityPriceError = Class.new(StandardError)
  MissingStartPriceError    = Class.new(StandardError)

  PROVISIONAL_LOOKBACK_DAYS = 7

  attr_reader :provider_error

  def initialize(security:, security_provider:, start_date:, end_date:, clear_cache: false)
    @security          = security
    @security_provider = security_provider
    @start_date        = start_date
    @end_date          = normalize_end_date(end_date)
    @clear_cache       = clear_cache
  end

  # Constructs a daily series of prices for a single security over the date range.
  # Returns the number of rows upserted.
  def import_provider_prices
    if !clear_cache && all_prices_exist?
      Rails.logger.info("No new prices to sync for #{security.ticker} between #{start_date} and #{end_date}, skipping")
      return 0
    end

    if provider_prices.empty?
      Rails.logger.warn("Could not fetch prices for #{security.ticker} between #{start_date} and #{end_date} because provider returned no prices")
      return 0
    end

    prev_price_value = start_price_value
    prev_currency = prev_price_currency || db_price_currency || "USD"

    # Fallback for holdings that predate the asset's listing on the provider
    # (e.g. a 2018 BTCEUR trade vs. Binance's 2020-01-03 listing date, or a
    # 2023 RDDT trade vs. the 2024-03-21 IPO on Yahoo/Twelve Data). We can't
    # anchor a price on or before start_date, but provider_prices has real
    # data later in the range — advance fill_start_date to the earliest
    # available provider date and use that price as the LOCF anchor. Days
    # before that are intentionally left out of the DB (honest gap) rather
    # than backfilled from a future price.
    advanced_first_price_on = nil

    if prev_price_value.blank?
      earliest_provider_price = provider_prices.values.min_by(&:date)

      if earliest_provider_price&.price.present? && earliest_provider_price.price.to_f > 0
        Rails.logger.info(
          "#{security.ticker}: no provider price on or before #{start_date}; " \
          "advancing gapfill start to earliest available #{earliest_provider_price.date}"
        )
        prev_price_value        = earliest_provider_price.price
        prev_currency           = earliest_provider_price.currency || prev_currency
        @fill_start_date        = earliest_provider_price.date
        advanced_first_price_on = earliest_provider_price.date
      end
    end

    unless prev_price_value.present?
      Rails.logger.error("Could not find a start price for #{security.ticker} on or before #{fill_start_date}")

      Sentry.capture_exception(MissingStartPriceError.new("Could not determine start price for ticker")) do |scope|
        scope.set_tags(security_id: security.id)
        scope.set_context("security", {
          id: security.id,
          start_date: fill_start_date
        })
      end

      return 0
    end

    gapfilled_prices = fill_start_date.upto(end_date).map do |date|
      db_price             = db_prices[date]
      db_price_value       = db_price&.price
      provider_price       = provider_prices[date]
      provider_price_value = provider_price&.price
      provider_currency    = provider_price&.currency

      has_provider_price = provider_price_value.present? && provider_price_value.to_f > 0
      has_db_price = db_price_value.present? && db_price_value.to_f > 0
      is_provisional = db_price&.provisional

      # Choose price and currency from the same source to avoid mismatches
      chosen_price, chosen_currency = if clear_cache || is_provisional
        # For provisional/cache clear: only use provider price, let gap-fill handle missing
        # This ensures stale DB values don't persist when provider has no weekend data
        [ provider_price_value, provider_currency ]
      elsif has_db_price
        # For non-provisional with valid DB price: preserve existing value (user edits)
        [ db_price_value, db_price&.currency ]
      else
        # Fill gaps with provider data
        [ provider_price_value, provider_currency ]
      end

      # Gap-fill using LOCF (last observation carried forward)
      # Treat nil or zero prices as invalid and use previous price/currency
      used_locf = false
      if chosen_price.nil? || chosen_price.to_f <= 0
        chosen_price = prev_price_value
        chosen_currency = prev_currency
        used_locf = true
      end
      prev_price_value = chosen_price
      prev_currency = chosen_currency || prev_currency

      provisional = determine_provisional_status(
        date: date,
        has_provider_price: has_provider_price,
        used_locf: used_locf,
        existing_provisional: db_price&.provisional
      )

      {
        security_id: security.id,
        date:        date,
        price:       chosen_price,
        currency:    chosen_currency || "USD",
        provisional: provisional
      }
    end

    result = upsert_rows(gapfilled_prices)

    # Persist the advanced start date so subsequent syncs can clamp
    # expected_count and short-circuit via all_prices_exist? instead of
    # re-iterating the full (start_date..end_date) range every time. Only
    # set on the first successful advance — clear_cache is the way to
    # recompute it if the provider later extends its history.
    if advanced_first_price_on.present? && security.first_provider_price_on.blank?
      security.update_column(:first_provider_price_on, advanced_first_price_on)
    end

    result
  end

  private
    attr_reader :security, :security_provider, :start_date, :end_date, :clear_cache

    # The start date sent to the provider API, clamped to the provider's max
    # lookback window when applicable. Computed independently of provider_prices
    # so fill_start_date can reference it without relying on method call order.
    def provider_fetch_start_date
      @provider_fetch_start_date ||= begin
        base = effective_start_date - PROVISIONAL_LOOKBACK_DAYS.days
        max_days = security_provider.respond_to?(:max_history_days) ? security_provider.max_history_days : nil

        if max_days && (end_date - base).to_i > max_days
          clamped = end_date - max_days.days
          Rails.logger.info(
            "#{security_provider.class.name} max history is #{max_days} days; " \
            "clamping #{security.ticker} start_date from #{base} to #{clamped}"
          )
          clamped
        else
          base
        end
      end
    end

    def provider_prices
      @provider_prices ||= begin
        response = security_provider.fetch_security_prices(
          symbol: security.ticker,
          exchange_operating_mic: security.exchange_operating_mic,
          start_date: provider_fetch_start_date,
          end_date: end_date
        )

        if response.success?
          Security.clear_plan_restriction(security.id, provider: security_provider.class.name.demodulize)
          response.data.index_by(&:date)
        else
          error_message = response.error.message
          Rails.logger.warn("#{security_provider.class.name} could not fetch prices for #{security.ticker} between #{provider_fetch_start_date} and #{end_date}. Provider error: #{error_message}")

          if Security.plan_upgrade_required?(error_message, provider: security_provider.class.name.demodulize)
            Security.record_plan_restriction(
              security_id: security.id,
              error_message: error_message,
              provider: security_provider.class.name.demodulize
            )
          end

          Sentry.capture_exception(MissingSecurityPriceError.new("Could not fetch prices for ticker"), level: :warning) do |scope|
            scope.set_tags(security_id: security.id)
            scope.set_context("security", { id: security.id, start_date: start_date, end_date: end_date })
          end

          @provider_error = error_message
          {}
        end
      end
    end

    def db_prices
      @db_prices ||= Security::Price.where(security_id: security.id, date: start_date..end_date)
                                    .order(:date)
                                    .to_a
                                    .index_by(&:date)
    end

    def all_prices_exist?
      return false if has_refetchable_provisional_prices?

      # Count only prices in the clamped range so pre-listing / pre-IPO gaps
      # don't perpetually trip the "expected_count mismatch" re-sync. Query
      # directly rather than via db_prices (which stays at the full range to
      # preserve any user-entered rows pre-listing).
      persisted_count = Security::Price
        .where(security_id: security.id, date: clamped_start_date..end_date)
        .count

      persisted_count == expected_count
    end

    def has_refetchable_provisional_prices?
      Security::Price.where(security_id: security.id, date: start_date..end_date)
                     .refetchable_provisional(lookback_days: PROVISIONAL_LOOKBACK_DAYS)
                     .exists?
    end

    def expected_count
      (clamped_start_date..end_date).count
    end

    # Effective start date after clamping to the security's known first
    # provider-available price date. Unlike start_date, this shrinks when the
    # provider's history (e.g. Binance BTCEUR listed 2020-01-03, RDDT IPO
    # 2024-03-21) begins after the user's original start_date. Falls through
    # to start_date for any security that has never tripped the fallback.
    def clamped_start_date
      @clamped_start_date ||= begin
        listed = security.first_provider_price_on
        listed.present? && listed > start_date ? listed : start_date
      end
    end

    # Skip over ranges that already exist unless clearing cache
    # Also includes dates with refetchable provisional prices
    def effective_start_date
      return start_date if clear_cache

      refetchable_dates = Security::Price.where(security_id: security.id, date: start_date..end_date)
                                         .refetchable_provisional(lookback_days: PROVISIONAL_LOOKBACK_DAYS)
                                         .pluck(:date)
                                         .to_set

      (start_date..end_date).detect do |d|
        !db_prices.key?(d) || refetchable_dates.include?(d)
      end || end_date
    end

    # The date the gap-fill loop starts from. When the provider's history was
    # clamped (e.g. Alpha Vantage 140 days), we start from the clamped window
    # instead of the original effective_start_date to avoid writing hundreds of
    # LOCF-filled prices for dates the provider can't actually serve.
    def fill_start_date
      @fill_start_date ||= [ provider_fetch_start_date, effective_start_date ].max
    end

    def start_price_value
      # When processing full range (first sync), use original behavior
      if fill_start_date == start_date
        provider_price_value = provider_prices.select { |date, _| date <= start_date }
                                              .max_by { |date, _| date }
                                              &.last&.price
        db_price_value = db_prices[start_date]&.price

        return provider_price_value if provider_price_value.present? && provider_price_value.to_f > 0
        return db_price_value if db_price_value.present? && db_price_value.to_f > 0
        return nil
      end

      # For partial range or clamped range, use the most recent data before fill_start_date
      cutoff_date = fill_start_date

      # First try provider prices (most recent before cutoff)
      provider_price_value = provider_prices
        .select { |date, _| date < cutoff_date }
        .max_by { |date, _| date }
        &.last&.price

      return provider_price_value if provider_price_value.present? && provider_price_value.to_f > 0

      # Fall back to most recent DB price before cutoff
      currency = prev_price_currency || db_price_currency
      Security::Price
        .where(security_id: security.id)
        .where("date < ?", cutoff_date)
        .where("price > 0")
        .where(provisional: false)
        .then { |q| currency.present? ? q.where(currency: currency) : q }
        .order(date: :desc)
        .limit(1)
        .pick(:price)
    end

    def determine_provisional_status(date:, has_provider_price:, used_locf:, existing_provisional:)
      # Provider returned real price => NOT provisional
      return false if has_provider_price

      # Gap-filled (LOCF) => provisional if recent (including weekends)
      # Weekend prices inherit uncertainty from Friday and get fixed via cascade
      # when the next weekday sync fetches correct Friday price
      if used_locf
        is_recent = date >= PROVISIONAL_LOOKBACK_DAYS.days.ago.to_date
        return is_recent
      end

      # Otherwise preserve existing status
      existing_provisional || false
    end

    def upsert_rows(rows)
      batch_size         = 200
      total_upsert_count = 0
      now = Time.current

      rows_with_timestamps = rows.map { |row| row.merge(updated_at: now) }

      rows_with_timestamps.each_slice(batch_size) do |batch|
        ids = Security::Price.upsert_all(
          batch,
          unique_by: %i[security_id date currency],
          returning: [ "id" ]
        )
        total_upsert_count += ids.count
      end

      total_upsert_count
    end

    def db_price_currency
      db_prices.values.first&.currency
    end

    def prev_price_currency
      @prev_price_currency ||= provider_prices.values.first&.currency
    end

    # Clamp to today (EST) so we never call our price API for a future date (our API is in EST/EDT timezone)
    def normalize_end_date(requested_end_date)
      today_est = Date.current.in_time_zone("America/New_York").to_date
      [ requested_end_date, today_est ].min
    end
end
