module Family::QuestradeConnectable
  extend ActiveSupport::Concern

  included do
    has_many :questrade_items, dependent: :destroy
  end

  def can_connect_questrade?
    # Families can configure their own Questrade credentials
    true
  end

  def create_questrade_item!(refresh_token:, api_server: nil, item_name: nil)
    questrade_item = questrade_items.create!(
      name: item_name || "Questrade Connection",
      refresh_token: refresh_token,
      api_server: api_server
    )

    questrade_item.sync_later

    questrade_item
  end

  def has_questrade_credentials?
    questrade_items.where.not(refresh_token: nil).exists?
  end
end
