class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  enum :source, { rule: "rule", plaid: "plaid", synth: "synth", ai: "ai", enable_banking: "enable_banking" }
end
