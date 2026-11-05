# frozen_string_literal: true

# Resolve the asset itself so a provider search cannot substitute a trading pair.
class BinanceAccount::SecurityResolver
  def self.resolve(ticker, symbol)
    Onchain::SecurityResolver.resolve(symbol: symbol.presence || ticker.to_s.delete_prefix("CRYPTO:"), canonicalize: false)
  end
end
