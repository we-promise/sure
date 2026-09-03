module Family::TradeRepublicConnectable
  extend ActiveSupport::Concern

  included do
    has_many :trade_republic_items, dependent: :destroy
  end

  def can_connect_trade_republic?
    true
  end
end
