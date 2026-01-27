module Family::MercuryConnectable
  extend ActiveSupport::Concern

  included do
    has_many :mercury_items, dependent: :destroy
  end

  def can_connect_mercury?
    # Families can configure their own Mercury credentials
    true
  end

  def create_mercury_item!(token:, base_url: nil, item_name: nil)
    mercury_item = mercury_items.create!(
      name: item_name || "Mercury Connection",
      token: token,
      base_url: base_url
    )

    mercury_item.sync_later

    mercury_item
  end

  def has_mercury_credentials?
    mercury_items.where.not(token: nil).exists?
  end
end
