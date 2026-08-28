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
    @errors = {}
    flexible_raw = fetch_flexible
    locked_raw = fetch_locked

    # Both sub-requests rescue to nil, so a double failure came back looking
    # exactly like "no Earn positions". The caller decides from these results
    # whether the wallet is empty, so it has to be told the difference.
    if flexible_raw.nil? && locked_raw.nil?
      return {
        assets: [],
        raw: { "flexible" => nil, "locked" => nil },
        source: "earn",
        error: @errors.values.uniq.join("; ").presence || "simple earn unavailable"
      }
    end

    # One side down does not fail the import, so the caller never records it —
    # and /settings/debug would show nothing at all about an endpoint that has
    # stopped answering, even though positions are being carried because of it.
    record_partial_failure if @errors.any?

    assets = merge_earn_assets(
      parse_flexible(flexible_raw),
      parse_locked(locked_raw)
    )

    {
      assets: restore_unavailable_side(assets, flexible_ok: !flexible_raw.nil?, locked_ok: !locked_raw.nil?),
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
      @errors["flexible"] = e.message
      Rails.logger.warn "BinanceItem::EarnImporter #{binance_item.id} - flexible failed: #{e.message}"
      nil
    end

    def fetch_locked
      provider.get_simple_earn_locked
    rescue => e
      @errors["locked"] = e.message
      Rails.logger.warn "BinanceItem::EarnImporter #{binance_item.id} - locked failed: #{e.message}"
      nil
    end

    # One side failing is not the whole source failing, so the caller cannot
    # carry the previous assets the way it does for a dead source — that would
    # discard the side that did answer. But dropping the silent side outright
    # removes live positions: a locked ETH holding would disappear because the
    # flexible call happened to be the one that worked.
    #
    # The two amounts are kept apart on every asset, so the missing side is
    # refilled from what it last reported and the working side stays fresh.
    def restore_unavailable_side(assets, flexible_ok:, locked_ok:)
      return assets if flexible_ok && locked_ok

      previous = previous_earn_assets
      return assets if previous.empty?

      merged = assets.index_by { |asset| asset[:symbol] }

      previous.each do |old|
        symbol = old["symbol"]
        current = merged[symbol]

        free   = flexible_ok ? current&.dig(:free).to_d : old["free"].to_d
        locked = locked_ok ? current&.dig(:locked).to_d : old["locked"].to_d
        total  = free + locked
        next if total.zero?

        merged[symbol] = {
          symbol: symbol, free: free.to_s("F"), locked: locked.to_s("F"), total: total.to_s("F")
        }
      end

      merged.values
    end

    def record_partial_failure
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Binance Simple Earn read only part of its positions",
        source: self.class.name,
        provider_key: "binance",
        family: binance_item.family,
        metadata: {
          binance_item_id: binance_item.id,
          unavailable_endpoints: @errors.keys,
          errors: @errors
        }
      )
    end

    def previous_earn_assets
      Array(
        binance_item.binance_accounts
                    .find_by(account_type: "combined")
                    &.raw_payload&.dig("assets")
      ).select { |asset| asset["source"] == "earn" }
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
        flex = flexible_totals[symbol] || BigDecimal("0")
        lock = locked_totals[symbol] || BigDecimal("0")
        total = flex + lock
        next if total.zero?

        { symbol: symbol, free: flex.to_s("F"), locked: lock.to_s("F"), total: total.to_s("F") }
      end
    end
end
