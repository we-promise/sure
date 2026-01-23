class Crypto < ApplicationRecord
  include Accountable

  # Subtypes differentiate how crypto is held:
  # - wallet: Self-custody or provider-synced wallets (CoinStats, etc.)
  # - exchange: Centralized exchanges with trade history (Coinbase, Kraken, etc.)
  SUBTYPES = {
    "wallet" => { short: "Wallet", long: "Crypto Wallet" },
    "exchange" => { short: "Exchange", long: "Crypto Exchange" }
  }.freeze

  # Crypto is taxable by default, but can be held in tax-advantaged accounts
  # (e.g., self-directed IRA, though rare)
  enum :tax_treatment, {
    taxable: "taxable",
    tax_deferred: "tax_deferred",
    tax_exempt: "tax_exempt"
  }, default: :taxable

  # Exchange accounts support manual trade entry; wallets are sync-only
  def supports_trades?
    subtype == "exchange"
  end

  class << self
    def color
      "#737373"
    end

    def classification
      "asset"
    end

    def icon
      "bitcoin"
    end

    def display_name
      "Crypto"
    end
  end
end
