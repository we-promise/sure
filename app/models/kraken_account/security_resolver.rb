# frozen_string_literal: true

# Resolves a Kraken asset to the security that represents it.
#
# One security per *asset*, never per trading pair. A position in BTC is one
# position whether it was bought with EUR, sold for USD or is sitting in an Earn
# wallet, so all of those must land on the same security or the holding is split
# across several, each looking a fraction of its real size.
#
# That rules out the generic resolver's provider search for this path: asked to
# resolve "CRYPTO:BTC" it answers with whatever pair its price provider ranks
# first -- BTCBRL, BTC-EUR, BTCUSD -- which is a different security each time the
# ranking moves, and never the one already in the database, because the ticker it
# returns is not the ticker that was asked for. A provider match is therefore
# accepted only when it comes back under the ticker we asked for.
class KrakenAccount::SecurityResolver
  EXCHANGE_MIC = "XKRA"

  # Kraken suffixes a staked or bonded balance onto the asset code -- XBT.M,
  # ETH2.S, DOT28.S -- and those are the same asset in a different wallet.
  STAKING_SUFFIX = /(\d+)?\.[A-Z]+\z/

  # Kraken's own legacy codes for the same asset: XBT and XXBT are BTC, XETH is
  # ETH, ZEUR is EUR. Shared with AssetNormalizer so a symbol canonicalised here
  # and one canonicalised there cannot disagree -- which is how BTC ended up
  # split across CRYPTO:BTC and CRYPTO:XBT.
  FIAT_PREFIXES = KrakenAccount::AssetNormalizer::FIAT_PREFIXES
  SYMBOL_FALLBACKS = KrakenAccount::AssetNormalizer::SYMBOL_FALLBACKS

  class << self
    def resolve(asset_symbol)
      asset = canonical_asset(asset_symbol)
      return nil if asset.blank?

      ticker = "CRYPTO:#{asset}"

      Security.find_by(ticker: ticker) ||
        provider_match(ticker) ||
        offline_security(ticker, asset)
    end

    # "XBT.M" -> "BTC", "DOT28.S" -> "DOT", "CRYPTO:ETH" -> "ETH"
    def canonical_asset(symbol)
      value = symbol.to_s.strip.upcase
      value = value.split(":", 2).last.to_s if value.include?(":")
      value = value.sub(STAKING_SUFFIX, "")
      value = FIAT_PREFIXES[value] || value
      SYMBOL_FALLBACKS[value] || value
    end

    private

      # Only a security carrying the ticker we asked for is this asset. Anything
      # else is a pair that merely mentions it.
      def provider_match(ticker)
        security = Security::Resolver.new(ticker).resolve
        return nil if security.nil?
        return security if security.ticker.to_s.casecmp?(ticker)

        Rails.logger.info(
          "KrakenAccount::SecurityResolver - ignoring #{security.ticker} for #{ticker}: a pair, not the asset"
        )
        nil
      rescue StandardError => e
        Rails.logger.warn "KrakenAccount::SecurityResolver - resolver failed for #{ticker}: #{e.message}"
        nil
      end

      def offline_security(ticker, asset)
        Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC).tap do |security|
          security.name = asset if security.name.blank?
          security.offline = true unless security.offline
          security.save! if security.changed?
        end
      end
  end
end
