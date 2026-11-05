# frozen_string_literal: true

# Resolve the asset itself so a provider search cannot substitute a trading pair.
# Resolution makes no provider call, so an error here comes from storing the
# security, which an offline fallback would hit too. It propagates on purpose: trades
# are cached only once processed, so the next sync retries them instead of
# losing them for good.
class BinanceAccount::SecurityResolver
  def self.resolve(ticker, symbol)
    Onchain::SecurityResolver.resolve(symbol: symbol.presence || ticker.to_s.delete_prefix("CRYPTO:"), canonicalize: false)
  end
end
