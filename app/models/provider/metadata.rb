class Provider
  module Metadata
    REGISTRY = {
      simplefin:      { region: "US",      kind: "Bank",       maturity: :stable, logo_text: "SF" },
      lunchflow:      { region: "US",      kind: "Bank",       maturity: :stable, logo_text: "LF" },
      enable_banking: { region: "EU",      kind: "Bank",       maturity: :beta,   logo_text: "EB" },
      coinstats:      { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "CS" },
      mercury:        { region: "US",      kind: "Bank",       maturity: :beta,   logo_text: "ME" },
      coinbase:       { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "CB" },
      binance:        { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "BI" },
      snaptrade:      { region: "US / CA", kind: "Investment", maturity: :beta,   logo_text: "ST" },
      indexa_capital: { region: "ES",      kind: "Investment", maturity: :alpha,  logo_text: "IC" },
      sophtron:       { region: "US",      kind: "Bank",       maturity: :alpha,  logo_text: "SO" },
      plaid:          { region: "US",      kind: "Bank",       tier: "Paid", maturity: :stable, logo_text: "PL" },
      plaid_eu:       { name: "Plaid EU", region: "EU",        kind: "Bank",       tier: "Paid", maturity: :stable, logo_text: "PL" }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase }
    end
  end
end
