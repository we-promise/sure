# frozen_string_literal: true

# Orchestrates all Binance sub-importers and upserts a single combined BinanceAccount.
class BinanceItem::Importer
  # Every sub-importer swallows its own error and answers with an empty asset
  # list, so "the wallet is empty" and "nothing could be fetched" arrive here
  # looking identical. Raising on the second keeps the sync honest instead of
  # reporting a successful import of nothing.
  class AllRequestsFailed < StandardError; end

  attr_reader :binance_item, :binance_provider

  def initialize(binance_item, binance_provider:)
    @binance_item = binance_item
    @binance_provider = binance_provider
  end

  def import
    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - starting import"

    spot_result   = BinanceItem::SpotImporter.new(binance_item, provider: binance_provider).import
    margin_result = BinanceItem::MarginImporter.new(binance_item, provider: binance_provider).import
    earn_result   = BinanceItem::EarnImporter.new(binance_item, provider: binance_provider).import
    futures_result = BinanceItem::FuturesImporter.new(binance_item, provider: binance_provider).import

    results = [ spot_result, margin_result, earn_result, futures_result ]
    all_assets = results.flat_map { |result| tagged_assets(result) }

    if results.all? { |result| result[:error].present? }
      raise AllRequestsFailed, results.filter_map { |result| result[:error] }.uniq.join("; ")
    end

    # A source that failed tells us nothing about what it holds, and the
    # holdings processor removes anything missing from this list. Writing only
    # the sources that answered would therefore delete live positions on a
    # transient error or a permission-scoped key. Their last known assets are
    # carried instead: stale until the source answers again, which beats gone.
    all_assets += carried_over_assets(results)

    # An emptied wallet still has to be written down. Returning here left the
    # previous payload in place, and the holdings processor reads that payload —
    # so assets already sold were re-imported as today's holdings on every sync
    # and never went away. Only skipped when there is nothing to correct yet.
    if all_assets.empty? && binance_item.binance_accounts.find_by(account_type: "combined").nil?
      return { success: true, assets_imported: 0, total_usd: 0 }
    end

    total_usd = calculate_total_usd(all_assets)

    upsert_binance_account(
      all_assets: all_assets,
      total_usd: total_usd,
      spot_raw: spot_result[:raw],
      margin_raw: margin_result[:raw],
      earn_raw: earn_result[:raw],
      futures_raw: futures_result[:raw]
    )

    binance_item.upsert_binance_snapshot!({
      "spot" => spot_result[:raw],
      "margin" => margin_result[:raw],
      "earn" => earn_result[:raw],
      "futures" => futures_result[:raw],
      "imported_at" => Time.current.iso8601
    })

    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - imported #{all_assets.size} assets, total_usd=#{total_usd}"

    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    def tagged_assets(result)
      result[:assets].map { |a| a.merge(source: result[:source]) }
    end

    def carried_over_assets(results)
      failed = results.select { |result| result[:error].present? }
      return [] if failed.empty?

      # A partial failure returns normally, so it never reaches the rescue in
      # BinanceItem#import_latest_binance_data. Without this the only trace is
      # an application log line, and support has nothing against the connection
      # saying part of the wallet went unread.
      record_partial_failure(failed)

      sources = failed.map { |result| result[:source] }
      previous = binance_item.binance_accounts.find_by(account_type: "combined")&.raw_payload&.dig("assets")
      return [] if previous.blank?

      carried = previous
        .map(&:deep_symbolize_keys)
        .select { |asset| sources.include?(asset[:source]) }

      if carried.any?
        Rails.logger.warn(
          "BinanceItem::Importer #{binance_item.id} - carrying #{carried.size} asset(s) " \
          "from unavailable source(s): #{sources.join(', ')}"
        )
      end

      carried
    end

    def record_partial_failure(failed)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Binance import read only part of the wallet",
        source: self.class.name,
        provider_key: "binance",
        family: binance_item.family,
        metadata: {
          binance_item_id: binance_item.id,
          unavailable_sources: failed.map { |result| result[:source] },
          errors: failed.to_h { |result| [ result[:source], result[:error] ] }
        }
      )
    end

    def calculate_total_usd(assets)
      assets.sum do |asset|
        quantity = asset[:total].to_d
        next 0 if quantity.zero?

        price = price_for(asset[:symbol])
        quantity * price
      end.round(2)
    end

    def price_for(symbol)
      return 1.0 if BinanceAccount::STABLECOINS.include?(symbol)

      price = binance_provider.get_spot_price("#{symbol}USDT")
      price.to_d
    rescue => e
      Rails.logger.warn "BinanceItem::Importer - could not get price for #{symbol}: #{e.message}"
      0
    end

    def upsert_binance_account(all_assets:, total_usd:, spot_raw:, margin_raw:, earn_raw:, futures_raw:)
      ba = binance_item.binance_accounts.find_or_initialize_by(account_type: "combined")

      ba.assign_attributes(
        name: binance_item.institution_name.presence || "Binance",
        currency: "USD",
        current_balance: total_usd,
        institution_metadata: build_institution_metadata(all_assets),
        raw_payload: {
          "spot" => spot_raw,
          "margin" => margin_raw,
          "earn" => earn_raw,
          "futures" => futures_raw,
          "assets" => all_assets.map(&:stringify_keys),
          "fetched_at" => Time.current.iso8601
        }
      )

      ba.save!
      ba
    end

    def build_institution_metadata(all_assets)
      %w[spot margin earn futures].each_with_object({}) do |source, hash|
        source_assets = all_assets.select { |a| a[:source] == source }
        hash[source] = {
          "asset_count" => source_assets.size,
          "assets" => source_assets.map { |a| a[:symbol] }
        }
      end
    end
end
