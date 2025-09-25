class ProviderMerchant < Merchant
  enum :source, { plaid: "plaid", synth: "synth", ai: "ai", enable_banking: "enable_banking" }

  validates :name, uniqueness: { scope: [ :source ] }
  validates :source, presence: true
end
