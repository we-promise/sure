module Family::TruelayerConnectable
  extend ActiveSupport::Concern

  included do
    has_many :truelayer_items, dependent: :destroy
  end

  def can_connect_truelayer?
    true
  end

  def has_truelayer_credentials?
    truelayer_items.where.not(client_id: nil).exists?
  end

  # A connection to start a new bank consent with: an unconnected one if there
  # is one, otherwise a new one carrying the existing app credentials.
  def truelayer_item_for_new_connection
    credentials = truelayer_items.active.where.not(client_id: nil).order(:created_at).first
    return nil unless credentials

    truelayer_items.active.find_by(refresh_token: nil) ||
      truelayer_items.create!(
        name: I18n.t("truelayer_items.default_name", default: "TrueLayer Connection"),
        client_id: credentials.client_id,
        client_secret: credentials.client_secret
      )
  end
end
