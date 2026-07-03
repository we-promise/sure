module Family::WiseConnectable
  extend ActiveSupport::Concern

  included do
    has_many :wise_items, dependent: :destroy
  end

  def can_connect_wise?
    true
  end

  def has_wise_credentials?
    wise_items.where.not(api_token: nil).exists?
  end

  def create_wise_item!(api_token:, item_name: nil)
    item = wise_items.create!(
      name: item_name || "Wise Connection",
      api_token: api_token
    )
    item.sync_later
    item
  end
end
