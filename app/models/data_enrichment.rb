class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  # Why a sync excluded an entry (see Entry.record_auto_exclusions).
  scope :sync_exclusion, -> { where(source: "sync", attribute_name: "excluded") }

  enum :source, {
    rule: "rule",
    plaid: "plaid",
    simplefin: "simplefin",
    lunchflow: "lunchflow",
    akahu: "akahu",
    up: "up",
    monobank: "monobank",
    synth: "synth",
    ai: "ai",
    sync: "sync",
    enable_banking: "enable_banking",
    coinstats: "coinstats",
    mercury: "mercury",
    brex: "brex",
    indexa_capital: "indexa_capital",
    sophtron: "sophtron",
    ibkr: "ibkr",
    questrade: "questrade",
    redbark: "redbark",
    trade_republic: "trade_republic",
    bayes: "bayes",
    similar: "similar",
    fio: "fio"
  }
end
