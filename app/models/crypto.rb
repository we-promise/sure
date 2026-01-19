class Crypto < ApplicationRecord
  include Accountable

  # Crypto is taxable by default, but can be held in tax-advantaged accounts
  # (e.g., self-directed IRA, though rare)
  enum :tax_treatment, {
    taxable: "taxable",
    tax_deferred: "tax_deferred",
    tax_exempt: "tax_exempt"
  }, default: :taxable

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
