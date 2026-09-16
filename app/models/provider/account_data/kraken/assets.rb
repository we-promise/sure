class Provider::AccountData::Kraken::Assets
  FIAT_PREFIXES = { "ZUSD" => "USD", "ZEUR" => "EUR", "ZGBP" => "GBP", "ZCAD" => "CAD",
    "ZAUD" => "AUD", "ZCHF" => "CHF", "ZJPY" => "JPY" }.freeze
  SYMBOL_FALLBACKS = { "XBT" => "BTC", "XXBT" => "BTC", "XETH" => "ETH", "ZUSD" => "USD" }.freeze

  def initialize(metadata = {})
    raise ArgumentError unless metadata.is_a?(Hash)
    @metadata = metadata.deep_stringify_keys
  end

  def normalize(raw_asset)
    raise ArgumentError unless raw_asset.is_a?(String) && raw_asset.present?
    raw = raw_asset.upcase
    suffix = raw[/(\.[A-Z])\z/, 1]
    base = suffix ? raw.delete_suffix(suffix) : raw
    details = metadata[raw] || metadata[base] || metadata.values.find do |candidate|
      [ raw, base ].include?(metadata_symbol(candidate, base).to_s.upcase)
    end
    symbol = metadata_symbol(details, base).to_s.upcase
    symbol = FIAT_PREFIXES.fetch(symbol, symbol)
    symbol = SYMBOL_FALLBACKS.fetch(symbol, symbol)
    { "raw_asset" => raw, "raw_base" => base, "symbol" => suffix ? "#{symbol}#{suffix}" : symbol,
      "price_symbol" => symbol, "suffix" => suffix }
  end

  def pair_symbols(pair, pairs:)
    pairs = pairs.deep_stringify_keys
    details = pairs[pair] || pairs.values.find { |candidate| candidate.is_a?(Hash) && candidate["altname"].to_s == pair }
    return [ normalize(details.fetch("base")).fetch("symbol"), normalize(details.fetch("quote")).fetch("symbol") ] if details

    %w[USDT USDC USD EUR GBP BTC ETH].each do |quote|
      return [ normalize(pair.delete_suffix(quote)).fetch("symbol"), quote ] if pair.end_with?(quote)
    end
    [ pair, "USD" ]
  end

  private
    attr_reader :metadata

    def metadata_symbol(value, fallback)
      return fallback unless value.is_a?(Hash)
      value["altname"].presence || value["display_name"].presence || fallback
    end
end
