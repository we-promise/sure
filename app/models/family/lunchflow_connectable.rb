module Family::LunchflowConnectable
  extend ActiveSupport::Concern

  included do
    has_many :lunchflow_items, dependent: :destroy
  end

  def can_connect_lunchflow?
    # Families can now configure their own Lunchflow credentials
    true
  end

  def create_lunchflow_item!(api_key:, base_url: nil, item_name: nil)
    lunchflow_item = lunchflow_items.create!(
      name: item_name || "Lunch Flow Connection",
      api_key: api_key,
      base_url: base_url
    )

    lunchflow_item.sync_later

    lunchflow_item
  end

  def has_lunchflow_credentials?
    lunchflow_items.where.not(api_key: nil).exists?
  end
end
