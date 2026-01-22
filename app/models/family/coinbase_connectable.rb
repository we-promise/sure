module Family::CoinbaseConnectable
  extend ActiveSupport::Concern

  included do
    has_many :coinbase_items, dependent: :destroy
  end

  def can_connect_coinbase?
    # Families can configure their own Coinbase credentials
    true
  end

  def create_coinbase_item!(api_key:, api_secret:, item_name: nil)
    coinbase_item = coinbase_items.create!(
      name: item_name || "Coinbase",
      api_key: api_key,
      api_secret: api_secret
    )

    coinbase_item.sync_later

    coinbase_item
  end

  def has_coinbase_credentials?
    coinbase_items.where.not(api_key: nil).exists?
  end
end
