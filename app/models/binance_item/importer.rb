# frozen_string_literal: true

# Orchestrates all Binance sub-importers and upserts a single combined BinanceAccount.
class BinanceItem::Importer
  STABLECOINS = %w[USDT BUSD FDUSD TUSD USDC DAI].freeze

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

    all_assets = tagged_assets(spot_result) + tagged_assets(margin_result) + tagged_assets(earn_result)

    if all_assets.empty?
      Rails.logger.info "BinanceItem::Importer #{binance_item.id} - no assets found, skipping account upsert"
      return { success: true, assets_imported: 0 }
    end

    total_usd = calculate_total_usd(all_assets)

    upsert_binance_account(
      all_assets: all_assets,
      total_usd: total_usd,
      spot_raw: spot_result[:raw],
      margin_raw: margin_result[:raw],
      earn_raw: earn_result[:raw]
    )

    binance_item.upsert_binance_snapshot!({
      "spot" => spot_result[:raw],
      "margin" => margin_result[:raw],
      "earn" => earn_result[:raw],
      "imported_at" => Time.current.iso8601
    })

    Rails.logger.info "BinanceItem::Importer #{binance_item.id} - imported #{all_assets.size} assets, total_usd=#{total_usd}"

    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    def tagged_assets(result)
      result[:assets].map { |a| a.merge(source: result[:source]) }
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
      return 1.0 if STABLECOINS.include?(symbol)

      price = binance_provider.get_spot_price("#{symbol}USDT")
      price.to_d
    rescue => e
      Rails.logger.warn "BinanceItem::Importer - could not get price for #{symbol}: #{e.message}"
      0
    end

    def upsert_binance_account(all_assets:, total_usd:, spot_raw:, margin_raw:, earn_raw:)
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
          "assets" => all_assets.map(&:stringify_keys),
          "fetched_at" => Time.current.iso8601
        }
      )

      ba.save!
      ba
    end

    def build_institution_metadata(all_assets)
      %w[spot margin earn].each_with_object({}) do |source, hash|
        source_assets = all_assets.select { |a| a[:source] == source }
        hash[source] = {
          "asset_count" => source_assets.size,
          "assets" => source_assets.map { |a| a[:symbol] }
        }
      end
    end
end
