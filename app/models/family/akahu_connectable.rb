module Family::AkahuConnectable
  extend ActiveSupport::Concern

  included do
    has_many :akahu_items, dependent: :destroy
  end

  def can_connect_akahu?
    true
  end

  def create_akahu_item!(app_token:, user_token:, base_url: nil, item_name: nil)
    akahu_item = akahu_items.create!(
      name: item_name || "Akahu Connection",
      app_token: app_token,
      user_token: user_token,
      base_url: base_url
    )

    akahu_item.sync_later
    akahu_item
  end

  def has_akahu_credentials?
    akahu_items.active.any?(&:credentials_configured?)
  end
end
