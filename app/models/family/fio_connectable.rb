module Family::FioConnectable
  extend ActiveSupport::Concern

  included do
    has_many :fio_items, dependent: :destroy
  end

  # Whether this family may connect Fio accounts (always true).
  def can_connect_fio?
    true
  end

  # Create a Fio connection with the given API token and start its first sync. A token
  # reaches one account, so a family with several Fio accounts creates several items.
  def create_fio_item!(token:, item_name: nil, sync_start_date: nil)
    fio_item = fio_items.create!(
      name: item_name.presence || I18n.t("family.fio.create_fio_item.default_name"),
      token: token,
      sync_start_date: sync_start_date
    )

    fio_item.sync_later
    fio_item
  end

  # True when any active Fio item has usable credentials.
  def has_fio_credentials?
    fio_items.active.any?(&:credentials_configured?)
  end
end
