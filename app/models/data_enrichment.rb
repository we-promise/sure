class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  enum :source, { rule: "rule", plaid: "plaid", simplefin: "simplefin", lunchflow: "lunchflow", synth: "synth", ai: "ai", enable_banking: "enable_banking", traderepublic: "traderepublic", coinstats: "coinstats", mercury: "mercury", indexa_capital: "indexa_capital" }
end
