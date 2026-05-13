module Family::IbkrConnectable
  extend ActiveSupport::Concern

  included do
    has_many :ibkr_items, dependent: :destroy
  end

  def can_connect_ibkr?
    true
  end

  def create_ibkr_item!(query_id:, token:, item_name: nil)
    ibkr_item = ibkr_items.create!(
      name: item_name.presence || "Interactive Brokers",
      query_id: query_id,
      token: token
    )

    ibkr_item.sync_later
    ibkr_item
  end
end
