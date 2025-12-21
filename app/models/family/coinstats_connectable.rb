module Family::CoinstatsConnectable
  extend ActiveSupport::Concern

  included do
    has_many :coinstats_items, dependent: :destroy
  end

  def can_connect_coinstats?
    # Families can configure their own Coinstats credentials
    true
  end

  def create_coinstats_item!(api_key:, item_name: nil)
    coinstats_item = coinstats_items.create!(
      name: item_name || "CoinStats Connection",
      api_key: api_key
    )

    coinstats_item.sync_later

    coinstats_item
  end

  def has_coinstats_credentials?
    coinstats_items.where.not(api_key: nil).exists?
  end
end
