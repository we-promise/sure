class Provider
  module Metadata
    REGISTRY = {
      akahu:          { region: "NZ",      kinds: %w[Bank Investment], maturity: :beta,   logo_text: "AK", logo_color: "#059669", domain: "akahu.nz" },
      simplefin:      { region: "US",      kinds: %w[Bank Investment], maturity: :stable, logo_text: "SF", logo_color: "#2563eb", domain: "simplefin.org" },
      lunchflow:      { region: "Global",  kinds: %w[Bank],            maturity: :stable, logo_text: "LF", logo_color: "#f97316", domain: "lunchflow.app" },
      up:             { region: "AU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "UP", logo_color: "#ea580c", domain: "up.com.au" },
      monobank:       { region: "UA",      kinds: %w[Bank],            maturity: :alpha,  logo_text: "MB", logo_color: "#111827", domain: "monobank.ua" },
      enable_banking: { region: "EU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "EB", logo_color: "#9333ea", domain: "enablebanking.com" },
      coinstats:      { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "CS", logo_color: "#db2777", domain: "coinstats.app" },
      wise:           { region: "Global",  kinds: %w[Bank],            maturity: :beta,   logo_text: "WI", logo_color: "#22c55e", domain: "wise.com" },
      mercury:        { region: "US",      kinds: %w[Bank],            maturity: :beta,   logo_text: "ME", logo_color: "#0891b2", domain: "mercury.com" },
      brex:           { region: "US",      kinds: %w[Bank],            maturity: :beta,   logo_text: "BX", logo_color: "#059669", domain: "brex.com" },
      coinbase:       { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "CB", logo_color: "#3b82f6", domain: "coinbase.com" },
      binance:        { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "BI", logo_color: "#ca8a04", domain: "binance.com" },
      kraken:         { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "KR", logo_color: "#7c3aed", domain: "kraken.com" },
      coinspot:       { region: "AU",      kinds: %w[Crypto],          maturity: :beta,   logo_text: "CS", logo_color: "#111827", domain: "coinspot.com.au", name: "CoinSpot" },
      snaptrade:      { region: "US / CA", kinds: %w[Investment],      maturity: :beta,   logo_text: "ST", logo_color: "#16a34a", domain: "snaptrade.com" },
      ibkr:           { region: "Global",  kinds: %w[Investment],      maturity: :beta,   logo_text: "IB", logo_color: "#dc2626", domain: "interactivebrokers.com" },
      indexa_capital: { region: "ES",      kinds: %w[Investment],      maturity: :alpha,  logo_text: "IC", logo_color: "#dc2626", domain: "indexacapital.com" },
      sophtron:       { region: "US",      kinds: %w[Bank Investment], maturity: :alpha,  logo_text: "SO", logo_color: "#0d9488", domain: "sophtron.com" },
      trading212:     { region: "EU",      kinds: %w[Investment],      maturity: :alpha,  logo_text: "T2", logo_color: "#0d9488", domain: "trading212.com" },
      trade_republic: { region: "EU",      kinds: %w[Bank Investment], maturity: :beta,   logo_text: "TR", logo_color: nil,       domain: "traderepublic.com" },
      plaid:          { region: "US",      kinds: %w[Bank],            maturity: :stable, logo_text: "PL", logo_color: "#4f46e5", domain: "plaid.com", tier: "Paid" },
      plaid_eu:       { region: "EU",      kinds: %w[Bank],            maturity: :stable, logo_text: "PL", logo_color: "#4f46e5", domain: "plaid.com", tier: "Paid", name: "Plaid EU" },
      questrade:      { region: "CA",      kinds: %w[Investment],      maturity: :beta,   logo_text: "QT", logo_color: "#0d9488", domain: "questrade.com" },
      pluggy:         { region: "BR",      kinds: %w[Bank Investment], maturity: :alpha,  logo_text: "Py", logo_bg: "bg-green-600" },
      redbark:        { region: "AU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "RB", logo_color: "#b91c1c", domain: "redbark.com" },
      onchain_wallet: { region: "Global",  kinds: %w[Crypto],          maturity: :alpha,  logo_text: "OC", logo_color: "#d97706", domain: nil, logo_icon: "wallet", name: "On-chain wallets" }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_color: nil }
    end

    # Brandfetch icon URL for the provider's own brand, or nil when the provider
    # has no domain or Brandfetch isn't configured. Unknown brands 404 instead of
    # returning Brandfetch's lettermark, so ProviderLogo keeps its own fallback.
    def self.logo_url(provider_key)
      domain = self.for(provider_key)[:domain]
      Setting.brand_fetch_icon_url(domain, fallback: "404")
    end
  end
end
