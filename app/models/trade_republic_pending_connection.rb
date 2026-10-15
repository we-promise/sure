# A new Trade Republic connection while its first login is in progress. The
# connection itself (a TradeRepublicItem) is created only once Trade Republic
# approves the login, so a cancelled or expired login leaves nothing behind.
class TradeRepublicPendingConnection < ApplicationRecord
  include Encryptable, TradeRepublicLoginState

  # Like on TradeRepublicItem, the PIN is used for the login request only.
  attr_accessor :pin, :qr_login

  if encryption_ready?
    encrypts :phone_number
    encrypts :pending_login_state
  end

  belongs_to :family

  # The login starts before the record is saved, so the device ID is set in
  # Ruby rather than left to the database default; Trade Republic has to see
  # the same device from the first request on.
  attribute :device_id, :uuid, default: -> { SecureRandom.uuid }

  # A QR login needs no phone number; a phone number and PIN login does.
  validates :phone_number, presence: true, on: :create, unless: :qr_login

  def reload(*)
    super.tap { @pin = nil }
  end

  def trade_republic_provider(pin: self.pin)
    Provider::TradeRepublicClient.new(phone_number: phone_number, pin: pin, device_id: device_id)
  end

  # Creates the connection with the approved session. Trade Republic has seen
  # this login's device ID, so the connection keeps it.
  def connect!(session_blob:, brokerage_account_id:)
    transaction do
      item = family.trade_republic_items.create!(
        name: I18n.t("trade_republic_items.defaults.name"),
        currency: currency.presence || family.currency,
        phone_number: phone_number,
        device_id: device_id,
        session_blob: session_blob,
        brokerage_account_id: brokerage_account_id,
        status: :good
      )
      destroy!
      item
    end
  end
end
