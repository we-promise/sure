# frozen_string_literal: true

# Fetches Binance Simple Earn (flexible + locked) positions.
# Merges both into a single asset list with source tag "earn".
class BinanceItem::EarnImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    flexible_raw = fetch_flexible
    locked_raw = fetch_locked

    assets = merge_earn_assets(
      parse_flexible(flexible_raw),
      parse_locked(locked_raw)
    )

    {
      assets: assets,
      raw: { "flexible" => flexible_raw, "locked" => locked_raw },
      source: "earn"
    }
  rescue => e
    Rails.logger.error "BinanceItem::EarnImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "earn", error: e.message }
  end

  private

    def fetch_flexible
      provider.get_simple_earn_flexible
    rescue => e
      Rails.logger.warn "BinanceItem::EarnImporter #{binance_item.id} - flexible failed: #{e.message}"
      nil
    end

    def fetch_locked
      provider.get_simple_earn_locked
    rescue => e
      Rails.logger.warn "BinanceItem::EarnImporter #{binance_item.id} - locked failed: #{e.message}"
      nil
    end

    def parse_flexible(raw)
      return {} unless raw.is_a?(Hash)

      (raw["rows"] || []).each_with_object({}) do |row, acc|
        symbol = row["asset"]
        amount = row["totalAmount"].to_d
        acc[symbol] = (acc[symbol] || 0) + amount
      end
    end

    def parse_locked(raw)
      return {} unless raw.is_a?(Hash)

      (raw["rows"] || []).each_with_object({}) do |row, acc|
        symbol = row["asset"]
        amount = row["amount"].to_d
        acc[symbol] = (acc[symbol] || 0) + amount
      end
    end

    # Merge two symbol→amount hashes and emit normalized asset list
    def merge_earn_assets(flexible_totals, locked_totals)
      all_symbols = (flexible_totals.keys + locked_totals.keys).uniq
      all_symbols.filter_map do |symbol|
        total = (flexible_totals[symbol] || 0) + (locked_totals[symbol] || 0)
        next if total.zero?

        { symbol: symbol, free: total.to_s, locked: "0.0", total: total.to_s }
      end
    end
end
