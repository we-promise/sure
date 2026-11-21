class OtherLiability < ApplicationRecord
  include Accountable

  class << self
    def default_liquidity_for(_subtype)
      "long_term"
    end

    def color
      "#737373"
    end

    def icon
      "minus"
    end

    def classification
      "liability"
    end
  end
end
