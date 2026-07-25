module Family::RedbarkConnectable
  extend ActiveSupport::Concern

  included do
    has_many :redbark_items, dependent: :destroy
  end

  def can_connect_redbark?
    # Families can configure their own Redbark credentials
    true
  end

  def create_redbark_item!(api_key:, item_name: nil)
    redbark_item = redbark_items.create!(
      name: item_name || I18n.t("redbark_items.default_name"),
      api_key: api_key
    )

    redbark_item.sync_later

    redbark_item
  end

  def has_redbark_credentials?
    redbark_items.where.not(api_key: nil).exists?
  end
end
