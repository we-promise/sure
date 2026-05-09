class Provider
  module Metadata
    REGISTRY = {
      simplefin: {
        region: "US",
        kind: "Bank",
        maturity: :stable,
        logo_bg: "bg-blue-600",
        logo_text: "SF"
      },
      lunchflow: {
        region: "US",
        kind: "Bank",
        maturity: :stable,
        logo_bg: "bg-orange-500",
        logo_text: "LF"
      },
      enable_banking: {
        region: "EU",
        kind: "Bank",
        maturity: :beta,
        logo_bg: "bg-purple-600",
        logo_text: "EB"
      },
      coinstats: {
        region: "Global",
        kind: "Crypto",
        maturity: :beta,
        logo_bg: "bg-yellow-500",
        logo_text: "CS"
      },
      mercury: {
        region: "US",
        kind: "Bank",
        maturity: :beta,
        logo_bg: "bg-cyan-600",
        logo_text: "ME"
      },
      coinbase: {
        region: "Global",
        kind: "Crypto",
        maturity: :beta,
        logo_bg: "bg-blue-500",
        logo_text: "CB"
      },
      binance: {
        region: "Global",
        kind: "Crypto",
        maturity: :beta,
        logo_bg: "bg-yellow-400",
        logo_text: "BI"
      },
      snaptrade: {
        region: "US / CA",
        kind: "Investment",
        maturity: :beta,
        logo_bg: "bg-green-600",
        logo_text: "ST"
      },
      indexa_capital: {
        region: "ES",
        kind: "Investment",
        maturity: :alpha,
        logo_bg: "bg-red-600",
        logo_text: "IC"
      },
      sophtron: {
        region: "US",
        kind: "Bank",
        maturity: :alpha,
        logo_bg: "bg-teal-600",
        logo_text: "SO"
      },
      plaid: {
        region: "US",
        kind: "Bank",
        tier: "Paid",
        maturity: :stable,
        logo_bg: "bg-indigo-600",
        logo_text: "PL"
      }
    }.freeze

    def self.for(provider_key)
      REGISTRY[provider_key.to_sym] || { logo_text: provider_key.to_s.first(2).upcase, logo_bg: "bg-gray-500" }
    end
  end
end
