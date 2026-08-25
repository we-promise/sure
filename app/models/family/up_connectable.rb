module Family::UpConnectable
  extend ActiveSupport::Concern

  included do
    has_many :up_items, dependent: :destroy
  end

  # Whether this family may connect Up Bank accounts (always true).
  def can_connect_up?
    true
  end

  # Create an Up item with the given token and trigger an initial sync.
  def create_up_item!(access_token:, item_name: nil)
    up_item = up_items.create!(
      name: item_name || I18n.t("family.up.create_up_item.default_name"),
      access_token: access_token
    )

    up_item.sync_later
    up_item
  end

  # True when any active Up item has usable credentials.
  def has_up_credentials?
    up_items.active.any?(&:credentials_configured?)
  end
end
