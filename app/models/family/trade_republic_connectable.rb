module Family::TradeRepublicConnectable
  extend ActiveSupport::Concern

  included do
    has_many :trade_republic_items, dependent: :destroy
    has_many :trade_republic_pending_connections, dependent: :destroy
  end

  def can_connect_trade_republic?
    true
  end
end
