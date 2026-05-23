class Provider
  module Metadata
    REGISTRY = {
      simplefin:      { region: "US",      kind: "Bank",       maturity: :stable, logo_text: "SF", logo_bg: "bg-blue-600" },
      lunchflow:      { region: "US",      kind: "Bank",       maturity: :stable, logo_text: "LF", logo_bg: "bg-orange-500" },
      enable_banking: { region: "EU",      kind: "Bank",       maturity: :beta,   logo_text: "EB", logo_bg: "bg-purple-600" },
      coinstats:      { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "CS", logo_bg: "bg-pink-600" },
      mercury:        { region: "US",      kind: "Bank",       maturity: :beta,   logo_text: "ME", logo_bg: "bg-cyan-600" },
      brex:           { region: "US",      kind: "Bank",       maturity: :beta,   logo_text: "BX", logo_bg: "bg-emerald-600" },
      coinbase:       { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "CB", logo_bg: "bg-blue-500" },
      binance:        { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "BI", logo_bg: "bg-yellow-600" },
      kraken:         { region: "Global",  kind: "Crypto",     maturity: :beta,   logo_text: "KR", logo_bg: "bg-violet-600" },
      snaptrade:      { region: "US / CA", kind: "Investment", maturity: :beta,   logo_text: "ST", logo_bg: "bg-green-600" },
      ibkr:           { region: "Global",  kind: "Investment", maturity: :beta,   logo_text: "IB", logo_bg: "bg-red-600" },
      indexa_capital: { region: "ES",      kind: "Investment", maturity: :alpha,  logo_text: "IC", logo_bg: "bg-red-600" },
      sophtron:       { region: "US",      kind: "Bank",       maturity: :alpha,  logo_text: "SO", logo_bg: "bg-teal-600" },
      plaid:          { region: "US",      kind: "Bank",       tier: "Paid", maturity: :stable, logo_text: "PL", logo_bg: "bg-indigo-600" },
      plaid_eu:       { name: "Plaid EU", region: "EU",        kind: "Bank",       tier: "Paid", maturity: :stable, logo_text: "PL", logo_bg: "bg-indigo-600" }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_bg: "bg-gray-500" }
    end
  end
end
