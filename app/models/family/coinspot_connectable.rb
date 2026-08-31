# frozen_string_literal: true

module Family::CoinspotConnectable
  extend ActiveSupport::Concern

  included do
    has_many :coinspot_items, dependent: :destroy
  end

  def can_connect_coinspot?
    true
  end

  def create_coinspot_item!(api_key:, api_secret:, item_name: nil)
    item = coinspot_items.create!(
      name: item_name || "CoinSpot",
      api_key: api_key,
      api_secret: api_secret
    )

    item.set_coinspot_institution_defaults!
    item.sync_later
    item
  end

  def has_coinspot_credentials?
    coinspot_items.active.any?(&:credentials_configured?)
  end
end
