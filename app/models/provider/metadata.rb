class Provider
  module Metadata
    REGISTRY = {
      akahu:          { region: "NZ",      kinds: %w[Bank Investment], maturity: :beta,   logo_text: "AK", logo_bg: "bg-emerald-600" },
      open_banking_io: { region: "EU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "OB", logo_bg: "bg-sky-600", name: "open-banking.io" },
      simplefin:      { region: "US",      kinds: %w[Bank Investment], maturity: :stable, logo_text: "SF", logo_bg: "bg-blue-600" },
      lunchflow:      { region: "Global",  kinds: %w[Bank],            maturity: :stable, logo_text: "LF", logo_bg: "bg-orange-500" },
      up:             { region: "AU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "UP", logo_bg: "bg-orange-600" },
      enable_banking: { region: "EU",      kinds: %w[Bank],            maturity: :beta,   logo_text: "EB", logo_bg: "bg-purple-600" },
      coinstats:      { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "CS", logo_bg: "bg-pink-600" },
      mercury:        { region: "US",      kinds: %w[Bank],            maturity: :beta,   logo_text: "ME", logo_bg: "bg-cyan-600" },
      brex:           { region: "US",      kinds: %w[Bank],            maturity: :beta,   logo_text: "BX", logo_bg: "bg-emerald-600" },
      coinbase:       { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "CB", logo_bg: "bg-blue-500" },
      binance:        { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "BI", logo_bg: "bg-yellow-600" },
      kraken:         { region: "Global",  kinds: %w[Crypto],          maturity: :beta,   logo_text: "KR", logo_bg: "bg-violet-600" },
      snaptrade:      { region: "US / CA", kinds: %w[Investment],      maturity: :beta,   logo_text: "ST", logo_bg: "bg-green-600" },
      ibkr:           { region: "Global",  kinds: %w[Investment],      maturity: :beta,   logo_text: "IB", logo_bg: "bg-red-600" },
      indexa_capital: { region: "ES",      kinds: %w[Investment],      maturity: :alpha,  logo_text: "IC", logo_bg: "bg-red-600" },
      sophtron:       { region: "US",      kinds: %w[Bank Investment], maturity: :alpha,  logo_text: "SO", logo_bg: "bg-teal-600" },
      plaid:          { region: "US",      kinds: %w[Bank],            maturity: :stable, logo_text: "PL", logo_bg: "bg-indigo-600", tier: "Paid" },
      plaid_eu:       { region: "EU",      kinds: %w[Bank],            maturity: :stable, logo_text: "PL", logo_bg: "bg-indigo-600", tier: "Paid", name: "Plaid EU" },
      questrade:      { region: "CA",      kinds: %w[Investment],      maturity: :beta,   logo_text: "QT", logo_bg: "bg-teal-600" }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_bg: "bg-gray-500" }
    end
  end
end
