# Backfills daily bullion closes from Yahoo Finance front-month futures
# (GC=F, SI=F, PL=F, PA=F) so past dates of a Gems and Bullion account can be
# valued from stored ExchangeRate rows. Futures settle close to spot but are
# not spot, so rows are stored as provisional "yahoo_futures" and never replace
# a spot quote or a close. Only trading days are stored; consumers carry the
# latest rate on or before a date forward over weekends and holidays.
class ValuablePriceHistory
  SOURCE = "yahoo_futures".freeze
  FUTURES_SYMBOLS = { "XAU" => "GC=F", "XAG" => "SI=F", "XPT" => "PL=F", "XPD" => "PA=F" }.freeze
  # Yahoo rejects chart ranges longer than five years.
  MAX_RANGE = 5.years - 1.day
  # Weekends and exchange holidays leave a few days without a close.
  START_SLACK = 7.days

  def initialize(account:, end_date: Date.current - 1.day)
    @account = account
    @end_date = end_date
  end

  # Returns the number of rows written.
  def import
    start_date = account.valuable.items.spot_valued.minimum(:acquired_on)
    return 0 unless start_date && start_date <= end_date

    symbols.sum { |symbol| import_symbol(symbol, start_date) }
  end

  private
    attr_reader :account, :end_date

    def provider = Provider::Registry.get_provider(:yahoo_finance)
    def currency = account.currency

    def symbols
      account.valuable.items.spot_valued.map(&:quote_symbol).compact.uniq & FUTURES_SYMBOLS.keys
    end

    def import_symbol(symbol, start_date)
      fetch_from = first_missing_date(symbol, start_date)
      return 0 if fetch_from > end_date

      closes = fetch_closes(symbol, fetch_from)
      return 0 if closes.empty?

      fx = usd_rates(closes.keys.min, closes.keys.max)
      stored = ExchangeRate.where(from_currency: symbol, to_currency: currency, date: closes.keys).index_by(&:date)

      closes.sum do |date, usd_price|
        existing = stored[date]
        next 0 if existing && existing.source != SOURCE # keep spot quotes and closes

        rate = fx_for(fx, date)
        next 0 unless rate

        row = existing || ExchangeRate.new(from_currency: symbol, to_currency: currency, date: date)
        row.update!(rate: usd_price * rate, source: SOURCE, provisional: true)
        1
      rescue ActiveRecord::RecordNotUnique
        0 # a concurrent valuation stored this day first
      end
    end

    # ponytail: resumes after the latest stored day; a gap in the middle of the
    # history (e.g. a provider outage) is only refilled by a full re-import.
    def first_missing_date(symbol, start_date)
      rates = ExchangeRate.where(from_currency: symbol, to_currency: currency, date: start_date..end_date)
      earliest = rates.minimum(:date)
      return start_date if earliest.nil? || earliest > start_date + START_SLACK

      rates.maximum(:date) + 1.day
    end

    # Returns { date => BigDecimal USD close } for the range.
    def fetch_closes(symbol, from)
      return {} unless provider

      closes = {}
      chunk_start = from
      while chunk_start <= end_date
        chunk_end = [ chunk_start + MAX_RANGE, end_date ].min
        response = provider.fetch_security_prices(symbol: FUTURES_SYMBOLS.fetch(symbol), start_date: chunk_start, end_date: chunk_end)

        if response.success?
          response.data.each { |p| closes[p.date] = p.price.to_d if p.price.to_d.positive? && (p.currency.presence || "USD") == "USD" }
        else
          log_failure(symbol, response.error)
        end
        chunk_start = chunk_end + 1.day
      end
      closes
    end

    def usd_rates(from, to)
      return {} if currency == "USD"

      ExchangeRate.import_provider_rates(from: "USD", to: currency, start_date: from - START_SLACK, end_date: to)
      ExchangeRate.where(from_currency: "USD", to_currency: currency, date: (from - START_SLACK)..to).pluck(:date, :rate).to_h
    end

    def fx_for(fx, date)
      return 1.to_d if currency == "USD"

      (0..START_SLACK.in_days.to_i).each do |offset|
        rate = fx[date - offset]
        return rate.to_d if rate
      end
      nil
    end

    def log_failure(symbol, error)
      DebugLogEntry.capture(category: symbol == "XAU" ? "gold_valuation" : "valuable_valuation", level: "warn", message: "#{SOURCE} #{symbol} history unavailable", source: "ValuablePriceHistory#fetch_closes", provider_key: "yahoo_finance", family: account.family, account: account, metadata: { account_id: account.id, symbol: symbol, error: error&.message })
    end
end
