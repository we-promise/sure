class PhysicalCash < ApplicationRecord
  include Accountable

  DEFAULT_SUBTYPE = "wallet"

  SUBTYPES = {
    "wallet" => { short: "Wallet", long: "Wallet" },
    "safe" => { short: "Safe", long: "Home Safe" },
    "piggy_bank" => { short: "Piggy Bank", long: "Piggy Bank" },
    "envelope" => { short: "Envelope", long: "Envelope / Budget Cash" },
    "other" => { short: "Other", long: "Other" }
  }.freeze

  class << self
    def color
      "#7A5AF8"
    end

    def classification
      "asset"
    end

    def icon
      "wallet"
    end
  end
end
