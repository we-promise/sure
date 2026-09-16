# Captured prices are data, not permission to query today's price during replay.
# Each quote includes its original unit and the dated FX conversion, if any.
class Provider::AccountData::OnchainWallet::Quotes
  MAX_DATES = 36_600
  attr_reader :evidence

  def initialize(raw, snapshot:, currency:, observed_at:, external_id:, ticker:)
    raise ArgumentError unless raw.is_a?(Hash)
    data = raw.deep_stringify_keys
    raise ArgumentError unless data.keys.sort == %w[currency current external_id historical observed_at snapshot_sha256 ticker version] && data["version"] == 1
    raise ArgumentError unless data["external_id"] == external_id && data["ticker"] == ticker
    raise ArgumentError unless data["currency"] == currency && data["snapshot_sha256"] == snapshot.fingerprint && Time.iso8601(data.fetch("observed_at")) == observed_at
    raise ArgumentError unless data["historical"].is_a?(Hash) && data["historical"].size <= MAX_DATES
    @currency = currency
    @current = data["current"] && quote(data["current"], latest: observed_at.to_date)
    @historical = data["historical"].to_h do |day, value|
      date = Date.iso8601(day)
      raise ArgumentError unless date.iso8601 == day
      raise ArgumentError if date > observed_at.to_date
      [ date, value && quote(value, latest: date, exact: true) ]
    end
    @evidence = Provider::AccountData::Page.new(records: [], complete: false, evidence: data).evidence
  rescue ArgumentError, KeyError, TypeError
    raise Provider::AccountData::InvalidResponse, "Invalid captured on-chain asset prices", cause: nil
  end

  def current
    @current
  end

  def on(date)
    @historical[date]
  end

  private
    def quote(raw, latest:, exact: false)
      raise ArgumentError unless raw.is_a?(Hash)
      raise ArgumentError unless raw.keys.sort == %w[date fx_date fx_rate original_currency original_price price]
      day = Date.iso8601(raw.fetch("date"))
      raise ArgumentError if day > latest || (exact && day != latest)
      original = decimal(raw.fetch("original_price"))
      price = decimal(raw.fetch("price"))
      raise ArgumentError if original.negative? || price.negative?
      raise ArgumentError unless raw["original_currency"].is_a?(String) && raw["original_currency"].match?(/\A[A-Z]{3}\z/)
      if raw["original_currency"] == @currency
        raise ArgumentError unless price == original && raw["fx_rate"].nil? && raw["fx_date"].nil?
      else
        rate = decimal(raw.fetch("fx_rate"))
        fx_day = Date.iso8601(raw.fetch("fx_date"))
        raise ArgumentError unless rate.positive? && fx_day <= latest && original * rate == price
      end
      price
    end

    def decimal(value)
      Provider::AccountData::OnchainWallet::SnapshotArchive.decimal(value)
    end
end
