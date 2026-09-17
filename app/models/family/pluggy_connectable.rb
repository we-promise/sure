module Family::PluggyConnectable
  extend ActiveSupport::Concern

  included do
    has_many :pluggy_items, dependent: :destroy
  end

  def can_connect_pluggy?
    # Families can configure their own Pluggy credentials
    true
  end

  def create_pluggy_item!(client_id:, client_secret:, item_name: nil)
    pluggy_item = pluggy_items.create!(
      name: item_name || "Pluggy Connection",
      client_id: client_id,
      client_secret: client_secret
    )

    pluggy_item.sync_later

    pluggy_item
  end

  def has_pluggy_credentials?
    pluggy_items.where.not(client_id: nil).exists?
  end
end
