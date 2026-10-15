# Adds a Trade Republic connection. QR login starts right away and shows its
# QR code in a new row; PIN login opens a row with the phone number and PIN
# form, like the PIN login of an existing connection.
class TradeRepublic::NewConnectionComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  DOM_ID = "trade-republic-add-connection".freeze

  # `pending_connection` redisplays a failed attempt with its phone number.
  def initialize(pending_connection:)
    @pending_connection = pending_connection
  end

  attr_reader :pending_connection

  def pin_form_id
    "#{DOM_ID}-pin"
  end

  def show_pin_form?
    pending_connection.phone_number.present?
  end
end
