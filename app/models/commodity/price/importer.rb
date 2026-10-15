# Builds a gap-filled daily price series per commodity from the provider data,
# carrying the last price forward over weekends and holidays (the same
# approach as Security::Price::Importer). Today's price and recent
# carried-forward days are provisional and refetched at most hourly. A spot
# price stored for a day is never replaced by a futures price for that day.
class Commodity::Price::Importer
  PROVISIONAL_LOOKBACK_DAYS = 7
  REFETCH_AFTER = 1.hour

  def initialize(metals:, start_date:, end_date:, clear_cache: false)
    @metals = metals
    @start_date = start_date
    @today = Date.current.in_time_zone("America/New_York").to_date
    @end_date = [ end_date, @today ].min
    @clear_cache = clear_cache
  end

  # Returns the number of rows upserted.
  def import
    return 0 if start_date > end_date

    fetch_from = clear_cache ? start_date : first_date_needing_prices
    return 0 unless fetch_from

    provider_prices = Commodity::Price.fetch_provider_prices(
      metals, start_date: fetch_from - PROVISIONAL_LOOKBACK_DAYS.days, end_date: end_date
    )

    rows = metals.flat_map { |metal| gapfilled_rows(metal, provider_prices[metal.code] || [], fetch_from) }
    upsert(rows)
  end

  private
    attr_reader :metals, :start_date, :end_date, :clear_cache

    def first_date_needing_prices
      metals.filter_map do |metal|
        complete = Commodity::Price.where(code: metal.code, date: start_date..end_date)
          .where("provisional = false OR updated_at > ?", REFETCH_AFTER.ago)
          .pluck(:date).to_set
        (start_date..end_date).detect { |d| !complete.include?(d) }
      end.min
    end

    def gapfilled_rows(metal, prices, fetch_from)
      return [] if prices.empty?

      by_date = prices.index_by(&:date)
      stored = Commodity::Price.where(code: metal.code, date: fetch_from..end_date).index_by(&:date)
      previous = prices.select { |p| p.date < fetch_from }.max_by(&:date) || latest_stored_before(metal.code, fetch_from)

      fetch_from.upto(end_date).filter_map do |date|
        price = by_date[date]
        existing = stored[date]

        if existing && price && better_source?(existing, price)
          previous = existing
          row(existing, date, provisional: date >= @today)
        elsif price
          previous = price
          row(price, date, provisional: date >= @today) # today's price is intraday
        elsif existing && !existing.provisional
          previous = existing
          nil # keep a real stored price over a carried-forward one
        elsif previous
          # Honest gap before the first known price; afterwards carry forward.
          row(previous, date, provisional: date >= PROVISIONAL_LOOKBACK_DAYS.days.ago.to_date)
        end
      end
    end

    def better_source?(a, b)
      rank = ->(price) { Commodity::Price::SOURCES.index(price.source) || Commodity::Price::SOURCES.size }
      rank.call(a) < rank.call(b)
    end

    def latest_stored_before(code, date)
      Commodity::Price.where(code: code).where("date < ?", date).order(date: :desc).first
    end

    def row(price, date, provisional:)
      { code: price.code, date: date, price: price.price, currency: price.currency, source: price.source, provisional: provisional }
    end

    def upsert(rows)
      now = Time.current
      rows.each_slice(500).sum do |batch|
        Commodity::Price.upsert_all(
          batch.map { |r| r.merge(created_at: now, updated_at: now) },
          unique_by: %i[code date currency],
          update_only: %i[price source provisional updated_at],
          record_timestamps: false,
          returning: [ "id" ]
        ).count
      end
    end
end
