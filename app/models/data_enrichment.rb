class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  enum :source, {
    rule: "rule",
    plaid: "plaid",
    simplefin: "simplefin",
    lunchflow: "lunchflow",
    synth: "synth",
    ai: "ai",
    enable_banking: "enable_banking",
    coinstats: "coinstats",
    mercury: "mercury",
    brex: "brex",
    indexa_capital: "indexa_capital",
    sophtron: "sophtron",
    ibkr: "ibkr"
  }
end
