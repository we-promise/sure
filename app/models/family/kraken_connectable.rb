module Family::KrakenConnectable
  extend ActiveSupport::Concern

  included do
    has_many :kraken_items, dependent: :destroy
  end

  def can_connect_kraken?
    true
  end

  def create_kraken_item!(api_key:, api_secret:, item_name: nil)
    kraken_item = kraken_items.create!(
      name: item_name || "Kraken",
      api_key: api_key,
      api_secret: api_secret
    )

    kraken_item.sync_later
    kraken_item
  end

  def has_kraken_credentials?
    kraken_items.where.not(api_key: nil).exists?
  end
end
