module Family::TruelayerConnectable
  extend ActiveSupport::Concern

  # A consent flow that has not called back within this long is taken to be
  # abandoned, and its connection can be handed to the next flow.
  PENDING_CONSENT_TIMEOUT = 15.minutes

  included do
    has_many :truelayer_items, dependent: :destroy
  end

  def can_connect_truelayer?
    true
  end

  def has_truelayer_credentials?
    truelayer_items.where.not(client_id: nil).exists?
  end

  # A connection to start a new bank consent with, carrying the existing app
  # credentials. Each flow gets its own row, reserved by touching it, so two
  # consents started before either calls back cannot complete onto the same
  # record and overwrite each other; a row whose flow was abandoned is reused.
  def truelayer_item_for_new_connection
    credentials = truelayer_items.active.where.not(client_id: nil).order(:created_at).first
    return nil unless credentials

    abandoned = truelayer_items.active.where(refresh_token: nil)
      .where(updated_at: ...PENDING_CONSENT_TIMEOUT.ago)
      .order(:created_at).first
    return abandoned.tap(&:touch) if abandoned

    truelayer_items.create!(
      name: I18n.t("truelayer_items.default_name", default: "TrueLayer Connection"),
      client_id: credentials.client_id,
      client_secret: credentials.client_secret
    )
  end
end
