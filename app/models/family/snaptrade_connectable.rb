module Family::SnaptradeConnectable
  extend ActiveSupport::Concern

  included do
    has_many :snaptrade_items, dependent: :destroy
  end

  def can_connect_snaptrade?
    # Families can configure their own Snaptrade credentials
    true
  end

  def create_snaptrade_item!(client_id:, consumer_key:, snaptrade_user_secret:, snaptrade_user_id: nil, item_name: nil)
    snaptrade_item = snaptrade_items.create!(
      name: item_name || "Snaptrade Connection",
      client_id: client_id,
      consumer_key: consumer_key,
      snaptrade_user_id: snaptrade_user_id,
      snaptrade_user_secret: snaptrade_user_secret
    )

    snaptrade_item.sync_later

    snaptrade_item
  end

  def has_snaptrade_credentials?
    snaptrade_items.where.not(client_id: nil).exists?
  end
end
