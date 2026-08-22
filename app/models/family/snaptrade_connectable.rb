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

    # snaptrade_user_id is optional here, and an unregistered item makes
    # import_latest_snaptrade_data raise "SnapTrade user not registered".
    # Registration schedules its own sync once it completes.
    snaptrade_item.sync_later if snaptrade_item.user_registered?

    snaptrade_item
  end

  def has_snaptrade_credentials?
    # Both halves are required to build a provider, so a stray client_id
    # without a consumer_key is not usable credentials.
    snaptrade_items.credentials_configured.exists?
  end
end
