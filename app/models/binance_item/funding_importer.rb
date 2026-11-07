# frozen_string_literal: true

class BinanceItem::FundingImporter
  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    raw = @provider.get_funding_account
    raise Provider::Binance::ApiError, "Invalid funding wallet response" unless raw.is_a?(Array)

    assets = raw.filter_map do |balance|
      free = balance["free"].to_d
      locked = %w[locked freeze withdrawing].sum { |key| balance[key].to_d }
      total = free + locked
      next if total.zero?

      { symbol: balance.fetch("asset"), free: free.to_s("F"), locked: locked.to_s("F"), total: total.to_s("F") }
    end
    { assets: assets, raw: raw, source: "funding" }
  rescue => error
    { assets: [], raw: nil, source: "funding", error: error.message }
  end
end
