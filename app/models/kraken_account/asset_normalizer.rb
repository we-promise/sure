# frozen_string_literal: true

class KrakenAccount::AssetNormalizer
  SUFFIX_PATTERN = /(\.[A-Z])\z/
  FIAT_PREFIXES = {
    "ZUSD" => "USD",
    "ZEUR" => "EUR",
    "ZGBP" => "GBP",
    "ZCAD" => "CAD",
    "ZAUD" => "AUD",
    "ZCHF" => "CHF",
    "ZJPY" => "JPY"
  }.freeze
  SYMBOL_FALLBACKS = {
    "XBT" => "BTC",
    "XXBT" => "BTC",
    "XETH" => "ETH",
    "ZUSD" => "USD"
  }.freeze

  def initialize(asset_metadata = {})
    @asset_metadata = asset_metadata || {}
  end

  def normalize(raw_asset)
    raw = raw_asset.to_s.upcase
    suffix = raw[SUFFIX_PATTERN, 1]
    raw_base = suffix ? raw.delete_suffix(suffix) : raw

    metadata = metadata_for(raw, raw_base)
    base_symbol = metadata_symbol(metadata, raw_base)
    normalized_base = normalize_base_symbol(base_symbol)
    symbol = suffix.present? ? "#{normalized_base}#{suffix}" : normalized_base

    {
      raw_asset: raw,
      raw_base: raw_base,
      symbol: symbol,
      price_symbol: normalized_base,
      suffix: suffix,
      metadata: metadata
    }
  end

  private

    attr_reader :asset_metadata

    def metadata_for(raw, raw_base)
      asset_metadata[raw] || asset_metadata[raw_base] || asset_metadata.values.find do |metadata|
        candidate = metadata_symbol(metadata, raw_base)
        [ raw, raw_base ].include?(candidate.to_s.upcase)
      end
    end

    def metadata_symbol(metadata, fallback)
      return fallback unless metadata.is_a?(Hash)

      metadata["altname"].presence || metadata["display_name"].presence || fallback
    end

    def normalize_base_symbol(symbol)
      value = symbol.to_s.upcase
      value = FIAT_PREFIXES[value] if FIAT_PREFIXES.key?(value)
      SYMBOL_FALLBACKS[value] || value
    end
end
