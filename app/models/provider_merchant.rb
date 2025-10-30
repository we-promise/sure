class ProviderMerchant < Merchant
  enum :source, { plaid: "plaid", simplefin: "simplefin", lunchflow: "lunchflow", synth: "synth", ai: "ai", enable_banking: "enable_banking" }

  validates :name, uniqueness: { scope: [ :source ] }
  validates :source, presence: true
end
