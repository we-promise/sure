# Acquisition is deliberately separate from wallet ingestion. Until the FX
# provider has a pinned bounded transport, only existing dated rates may be used.
class Provider::AccountData::OnchainWallet::CachedExchangeRateResolver
  def call(from:, to:, date:)
    raise ArgumentError unless from.match?(/\A[A-Z]{3}\z/) && to.match?(/\A[A-Z]{3}\z/) && date.instance_of?(Date)
    row = ExchangeRate.where(from_currency: from, to_currency: to, date: (date - 5)..date).order(date: :desc, id: :asc).first
    return unless row
    unless row.rate.is_a?(BigDecimal) && row.rate.finite? && row.rate.positive? && row.date <= date
      raise Provider::AccountData::InvalidResponse, "Invalid cached wallet exchange rate"
    end
    { rate: row.rate, date: row.date.iso8601, source: "cached_exchange_rate", id: row.id }
  end
end
