# frozen_string_literal: true

# Fetches Binance Margin account balances.
# Returns normalized asset list with source tag "margin".
class BinanceItem::MarginImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    raw = provider.get_margin_account
    assets = parse_assets(raw["userAssets"] || [])
    { assets: assets, raw: raw, source: "margin" }
  rescue => e
    Rails.logger.error "BinanceItem::MarginImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "margin", error: e.message }
  end

  private

    def parse_assets(user_assets)
      user_assets.filter_map do |a|
        # Use netAsset (assets minus borrowed) as the meaningful balance
        net = a["netAsset"].to_d
        free = a["free"].to_d
        locked = a["locked"].to_d
        total = free + locked
        next if total.zero? && net <= 0

        { symbol: a["asset"], free: free.to_s, locked: locked.to_s, total: total.to_s, net: net.to_s }
      end
    end
end
