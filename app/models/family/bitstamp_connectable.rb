# frozen_string_literal: true

module Family::BitstampConnectable
  extend ActiveSupport::Concern

  included do
    has_many :bitstamp_items, dependent: :destroy
  end

  def can_connect_bitstamp?
    true
  end

  def create_bitstamp_item!(api_key:, api_secret:, item_name: nil)
    item = bitstamp_items.create!(
      name: item_name || "Bitstamp",
      api_key: api_key,
      api_secret: api_secret
    )

    item.set_bitstamp_institution_defaults!
    item.sync_later
    item
  end

  def has_bitstamp_credentials?
    bitstamp_items.active.any?(&:credentials_configured?)
  end
end
