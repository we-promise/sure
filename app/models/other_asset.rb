class OtherAsset < ApplicationRecord
  include Accountable

  class << self
    def default_liquidity_for(_subtype)
      "long_term"
    end

    def color
      "#12B76A"
    end

    def icon
      "plus"
    end

    def classification
      "asset"
    end
  end
end
