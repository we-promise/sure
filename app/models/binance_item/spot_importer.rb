# frozen_string_literal: true

# Fetches Binance Spot wallet balances.
# Returns normalized asset list with source tag "spot".
class BinanceItem::SpotImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  # @return [Hash] { assets: [...], raw: <api_response>, source: "spot" }
  def import
    raw = provider.get_spot_account
    assets = parse_assets(raw["balances"] || [])
    { assets: assets, raw: raw, source: "spot" }
  rescue => e
    Rails.logger.error "BinanceItem::SpotImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "spot", error: e.message }
  end

  private

    def parse_assets(balances)
      balances.filter_map do |b|
        free = b["free"].to_d
        locked = b["locked"].to_d
        total = free + locked
        next if total.zero?

        { symbol: b["asset"], free: free.to_s, locked: locked.to_s, total: total.to_s }
      end
    end
end
