class Provider
  module Metadata
    REGISTRY = {
      akahu:          { region: "NZ",      kinds: %w[Bank Investment], maturity: :beta,   logo_text: "AK", logo_bg: "bg-emerald-600", domain: "akahu.nz" },
      simplefin:      { region: "US",      kinds: %w[Bank Investment], maturity: :stable, logo_text: "SF", logo_bg: "bg-blue-600",    domain: "simplefin.org" },
      lunchflow:      { region: "Global",  kinds: %w[Bank],            maturity: :stable, logo_text: "LF", logo_bg: "bg-orange-500",  domain: "lunchflow.app" },
      up:             { region: "AU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "UP", logo_bg: "bg-orange-600",  domain: "up.com.au" },
      monobank:       { region: "UA",      kinds: %w[Bank],            maturity: :alpha,  logo_text: "MB", logo_bg: "bg-inverse",     domain: "monobank.ua" },
      enable_banking: { region: "EU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "EB", logo_bg: "bg-purple-600",  domain: "enablebanking.com" },
      coinstats:      { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "CS", logo_bg: "bg-pink-600",    domain: "coinstats.app" },
      wise:           { region: "Global",  kinds: %w[Bank],            maturity: :beta,   logo_text: "WI", logo_bg: "bg-green-500",   domain: "wise.com" },
      mercury:        { region: "US",      kinds: %w[Bank],            maturity: :beta,   logo_text: "ME", logo_bg: "bg-cyan-600",    domain: "mercury.com" },
      brex:           { region: "US",      kinds: %w[Bank],            maturity: :beta,   logo_text: "BX", logo_bg: "bg-emerald-600", domain: "brex.com" },
      coinbase:       { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "CB", logo_bg: "bg-blue-500",    domain: "coinbase.com" },
      binance:        { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "BI", logo_bg: "bg-yellow-600",  domain: "binance.com" },
      kraken:         { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "KR", logo_bg: "bg-violet-600",  domain: "kraken.com" },
      snaptrade:      { region: "US / CA", kinds: %w[Investment],      maturity: :beta,   logo_text: "ST", logo_bg: "bg-green-600",   domain: "snaptrade.com" },
      ibkr:           { region: "Global",  kinds: %w[Investment],      maturity: :beta,   logo_text: "IB", logo_bg: "bg-red-600",     domain: "interactivebrokers.com" },
      indexa_capital: { region: "ES",      kinds: %w[Investment],      maturity: :alpha,  logo_text: "IC", logo_bg: "bg-red-600",     domain: "indexacapital.com" },
      sophtron:       { region: "US",      kinds: %w[Bank Investment], maturity: :alpha,  logo_text: "SO", logo_bg: "bg-teal-600",    domain: "sophtron.com" },
      trading212:     { region: "EU",      kinds: %w[Investment],      maturity: :alpha,  logo_text: "T2", logo_bg: "bg-teal-600",    domain: "trading212.com" },
      trade_republic: { region: "EU",      kinds: %w[Bank Investment], maturity: :beta,   logo_text: "TR", logo_bg: "bg-primary",     domain: "traderepublic.com" },
      plaid:          { region: "US",      kinds: %w[Bank],            maturity: :stable, logo_text: "PL", logo_bg: "bg-indigo-600",  domain: "plaid.com", tier: "Paid" },
      plaid_eu:       { region: "EU",      kinds: %w[Bank],            maturity: :stable, logo_text: "PL", logo_bg: "bg-indigo-600",  domain: "plaid.com", tier: "Paid", name: "Plaid EU" },
      questrade:      { region: "CA",      kinds: %w[Investment],      maturity: :beta,   logo_text: "QT", logo_bg: "bg-teal-600",    domain: "questrade.com" },
      redbark:        { region: "AU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "RB", logo_bg: "bg-red-700",     domain: "redbark.com" },
      onchain_wallet: { region: "Global",  kinds: %w[Crypto],          maturity: :alpha,  logo_text: "OC", logo_bg: "bg-amber-600",   domain: nil, logo_icon: "wallet", name: "On-chain wallets" }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_bg: "bg-gray-500" }
    end

    # Brandfetch icon URL for the provider's own brand, or nil when the provider
    # has no domain or Brandfetch isn't configured. Unknown brands 404 instead of
    # returning Brandfetch's lettermark, so ProviderLogo keeps its own fallback.
    def self.logo_url(provider_key)
      domain = self.for(provider_key)[:domain]
      client_id = Setting.brand_fetch_client_id
      return if domain.blank? || client_id.blank?

      size = Setting.brand_fetch_logo_size
      "https://cdn.brandfetch.io/#{domain}/icon/fallback/404/w/#{size}/h/#{size}?c=#{client_id}"
    end
  end
end
