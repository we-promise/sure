module Family::AkahuConnectable
  extend ActiveSupport::Concern

  included do
    has_many :akahu_items, dependent: :destroy
  end

  def can_connect_akahu?
    true
  end

  def create_akahu_item!(app_token:, user_token:, item_name: nil)
    akahu_item = akahu_items.create!(
      name: item_name || I18n.t("family.akahu.create_akahu_item.default_name"),
      app_token: app_token,
      user_token: user_token
    )

    akahu_item.sync_later
    akahu_item
  end

  def has_akahu_credentials?
    akahu_items.active.any?(&:credentials_configured?)
  end
end
