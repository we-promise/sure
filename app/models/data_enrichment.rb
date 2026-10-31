class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  # Why a sync excluded an entry (see Entry.record_auto_exclusions).
  scope :sync_exclusion, -> { where(source: "sync", attribute_name: "excluded") }

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
    similar: "similar",
    simplefin: "simplefin",
    sophtron: "sophtron",
    sync: "sync",
    synth: "synth",
    trade_republic: "trade_republic",
    up: "up"
  }
end
