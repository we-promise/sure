class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  # sorted
  enum :source, {
    ai: "ai",
    akahu: "akahu",
    bayes: "bayes",
    brex: "brex",
    coinstats: "coinstats",
    enable_banking: "enable_banking",
    fio: "fio",
    ibkr: "ibkr",
    indexa_capital: "indexa_capital",
    lunchflow: "lunchflow",
    mercury: "mercury",
    monobank: "monobank",
    plaid: "plaid",
    questrade: "questrade",
    redbark: "redbark",
    rule: "rule",
    sharesight: "sharesight",
    similar: "similar",
    simplefin: "simplefin",
    sophtron: "sophtron",
    synth: "synth",
    trade_republic: "trade_republic",
    up: "up"
  }
end
