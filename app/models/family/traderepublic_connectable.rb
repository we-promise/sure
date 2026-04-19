module Family::TraderepublicConnectable
  extend ActiveSupport::Concern

  included do
    has_many :traderepublic_items, dependent: :destroy
  end

  def can_connect_traderepublic?
    # Families can configure their own Trade Republic credentials
    true
  end

  def create_traderepublic_item!(phone_number:, pin:, item_name: nil)
    traderepublic_item = traderepublic_items.create!(
      name: item_name || "Trade Republic Connection",
      phone_number: phone_number,
      pin: pin
    )

    traderepublic_item.sync_later

    traderepublic_item
  end

  def has_traderepublic_credentials?
    traderepublic_items.where.not(phone_number: nil).exists?
  end
end
