module Family::BinanceConnectable
  extend ActiveSupport::Concern

  included do
    has_many :binance_items, dependent: :destroy
  end

  def can_connect_binance?
    true
  end

  def create_binance_item!(api_key:, api_secret:, item_name: nil)
    binance_item = binance_items.create!(
      name: item_name || "Binance",
      api_key: api_key,
      api_secret: api_secret
    )

    binance_item.sync_later
    binance_item
  end

  def has_binance_credentials?
    binance_items.where.not(api_key: nil).exists?
  end
end
