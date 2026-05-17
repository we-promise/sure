# frozen_string_literal: true

module Family::KrakenConnectable
  extend ActiveSupport::Concern

  included do
    has_many :kraken_items, dependent: :destroy
  end

  def can_connect_kraken?
    true
  end

  def create_kraken_item!(api_key:, api_secret:, item_name: nil)
    item = kraken_items.create!(
      name: item_name || "Kraken",
      api_key: api_key,
      api_secret: api_secret
    )

    item.set_kraken_institution_defaults!
    item.sync_later
    item
  end

  def has_kraken_credentials?
    kraken_items.active.any?(&:credentials_configured?)
  end
end
