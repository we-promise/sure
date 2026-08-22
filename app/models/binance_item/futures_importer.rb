# frozen_string_literal: true

# Pulls USDⓈ-M futures account data (balance and positions).
# Returns normalized asset list with source tag "futures".
class BinanceItem::FuturesImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  # @return [Hash] { assets: [...], raw: <api_response>, source: "futures" }
  def import
    raw = provider.get_futures_account

    # Binance Futures returns a slightly different format than spot
    # assets are in raw["assets"], positions in raw["positions"]

    assets = []

    # Process base assets (e.g. USDT, BUSD balances)
    Array(raw["assets"]).each do |asset|
      wallet_balance = asset["walletBalance"].to_d
      unrealized_profit = asset["unrealizedProfit"].to_d

      # Total equity is wallet balance + unrealized PNL
      total = wallet_balance + unrealized_profit

      next if total.zero?

      assets << {
        symbol: asset["asset"],
        free: asset["availableBalance"] || wallet_balance.to_s,
        locked: (wallet_balance - (asset["availableBalance"] || wallet_balance.to_s).to_d).to_s,
        total: total.to_s
      }
    end

    { assets: assets, raw: raw, source: "futures" }
  rescue => e
    Rails.logger.error "BinanceItem::FuturesImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "futures", error: e.message }
  end
end
