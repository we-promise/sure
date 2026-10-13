# frozen_string_literal: true

module Family::CoinspotConnectable
  extend ActiveSupport::Concern

  included do
    has_many :coinspot_items, dependent: :destroy
  end

  # Whether this family is allowed to connect a CoinSpot account. Always
  # true today; exists as the hook other connectable concerns use for
  # plan/feature gating.
  def can_connect_coinspot?
    true
  end

  # Creates a new CoinSpot connection with the given credentials, sets its
  # institution branding, and queues the first sync.
  def create_coinspot_item!(api_key:, api_secret:, item_name: nil)
    item = coinspot_items.create!(
      name: item_name.presence || I18n.t("coinspot_items.create.default_name"),
      api_key: api_key,
      api_secret: api_secret
    )

    item.set_coinspot_institution_defaults!
    item.sync_later
    item
  end

  # True when this family has at least one active CoinSpot connection with
  # both API credentials configured.
  def has_coinspot_credentials?
    coinspot_items.active.any?(&:credentials_configured?)
  end
end
