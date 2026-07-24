module Family::OpenBankingIoConnectable
  extend ActiveSupport::Concern

  included do
    has_many :open_banking_io_items, dependent: :destroy
  end

  def can_connect_open_banking_io?
    true
  end

  def create_open_banking_io_item!(api_base_url:, api_key:, private_key:, item_name: nil)
    open_banking_io_item = open_banking_io_items.create!(
      name: item_name || I18n.t("family.open_banking_io.create_open_banking_io_item.default_name"),
      api_base_url: api_base_url,
      api_key: api_key,
      private_key: private_key
    )

    open_banking_io_item.sync_later
    open_banking_io_item
  end

  def has_open_banking_io_credentials?
    open_banking_io_items.active.any?(&:credentials_configured?)
  end
end
