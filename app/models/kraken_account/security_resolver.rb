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
# returns is not the ticker that was asked for.
#
# The ticker is instead bound straight to the crypto price provider, exactly as
# Onchain::SecurityResolver does, and for the same reason. That also keeps one
# asset in one record across integrations: the CRYPTO: prefix is shared, so a
# coin held both on Kraken and on-chain is a single security rather than two.
class KrakenAccount::SecurityResolver
  TICKER_PREFIX = "CRYPTO:"

  # The only securities provider that prices bare crypto symbols.
  PRICE_PROVIDER = Onchain::SecurityResolver::PRICE_PROVIDER
  EXCHANGE_MIC = Onchain::SecurityResolver::EXCHANGE_MIC

  # Kraken suffixes a staked or bonded balance onto the asset code -- XBT.M,
  # ETH2.S, DOT28.S -- and those are the same asset in a different wallet. The
  # suffix can repeat: a balance payload reports bonded DOT as DOT28.S.S, so the
  # group is matched one-or-more times rather than once, or DOT28.S.S resolves to
  # a different security than the DOT28.S the ledger reports.
  #
  # The digits are only consumed ahead of a dot: LUNA2 stays LUNA2. Kraken has
  # no staked variant of an asset whose name ends in a digit today; if it ever
  # does, LUNA2.S would collapse to LUNA and this needs a table instead.
  STAKING_SUFFIX = /(?:\d*\.[A-Z]+)+\z/

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

      ticker = "#{TICKER_PREFIX}#{asset}"

      existing_security(ticker) || create_security(ticker, asset)
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

      # Does not require exchange_operating_mic to match: a Security for this
      # ticker may already exist because another integration created it first,
      # and reusing it keeps one asset in one record. The uniqueness index is on
      # (ticker, mic), so there can be more than one -- the previous Kraken code
      # created these at XKRA -- and the one at the crypto venue is preferred,
      # then the oldest, so the choice is stable across syncs.
      #
      # A security with no provider cannot be priced, so it is bound to the one
      # that quotes bare coin symbols and brought online. One with a provider
      # someone else chose, or one deliberately kept offline under a provider,
      # is left alone.
      def existing_security(ticker)
        security = Security.find_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC) ||
          Security.where(ticker: ticker).order(:created_at).first
        return nil if security.nil?

        security.update!(price_provider: PRICE_PROVIDER, offline: false) if security.price_provider.blank?
        security
      end

      def create_security(ticker, asset)
        Security.create!(
          ticker: ticker,
          name: asset,
          exchange_operating_mic: EXCHANGE_MIC,
          price_provider: PRICE_PROVIDER
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.warn "KrakenAccount::SecurityResolver - could not create #{ticker}: #{e.message}"
        Security.find_by(ticker: ticker)
      end
  end
end
