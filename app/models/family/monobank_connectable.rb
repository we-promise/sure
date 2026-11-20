module Family::MonobankConnectable
  extend ActiveSupport::Concern

  included do
    has_many :monobank_items, dependent: :destroy
  end

  # Whether this family may connect Monobank accounts (always true).
  def can_connect_monobank?
    true
  end

  # Create a Monobank connection with the given personal token and start its first sync.
  def create_monobank_item!(access_token:, item_name: nil)
    monobank_item = monobank_items.create!(
      name: item_name || I18n.t("family.monobank.create_monobank_item.default_name"),
      access_token: access_token
    )

    monobank_item.sync_later
    monobank_item
  end

  # True when any active Monobank item has usable credentials.
  def has_monobank_credentials?
    monobank_items.active.any?(&:credentials_configured?)
  end
end
