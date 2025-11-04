class ProviderMerchant < Merchant
  enum :source, { plaid: "plaid", simplefin: "simplefin", lunchflow: "lunchflow", synth: "synth", ai: "ai" }

  validates :name, uniqueness: { scope: [ :source ] }
  validates :source, presence: true
end
