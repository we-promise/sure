# Adds CoinStats connection capabilities to Family.
# Allows families to create and manage CoinStats API connections.
module Family::CoinstatsConnectable
  extend ActiveSupport::Concern

  included do
    has_many :coinstats_items, dependent: :destroy
  end

  # @return [Boolean] Whether the family can create CoinStats connections
  def can_connect_coinstats?
    # Families can configure their own Coinstats credentials
    true
  end

  # Creates a new CoinStats connection and triggers initial sync.
  # @param api_key [String] CoinStats API key
  # @param item_name [String, nil] Optional display name for the connection
  # @return [CoinstatsItem] The created connection
  def create_coinstats_item!(api_key:, item_name: nil)
    coinstats_item = coinstats_items.create!(
      name: item_name || "CoinStats Connection",
      api_key: api_key
    )

    coinstats_item.sync_later

    coinstats_item
  end

  # @return [Boolean] Whether the family has any configured CoinStats connections
  def has_coinstats_credentials?
    coinstats_items.where.not(api_key: nil).exists?
  end
end
