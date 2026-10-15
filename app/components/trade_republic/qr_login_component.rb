# The QR login button and panel, shared by the settings connection row and
# the Accounts page so a connection can log in again from either place.
# Given a block, the block replaces the button so a caller can place
# `button` among its own actions; the QR panel always follows it.
class TradeRepublic::QrLoginComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  # `record` is the connection logging in again or the pending connection
  # of a new one; both answer the same login routes.
  # `hide_button_while_polling` is for a row with its own Cancel, so a
  # running QR login doesn't show a second one.
  def initialize(record:, return_url:, active: false, code_svg: nil, hide_button_while_polling: false)
    @record = record
    @return_url = return_url
    @active = active
    @code_svg = code_svg
    @hide_button_while_polling = hide_button_while_polling
  end

  attr_reader :record, :return_url, :active, :code_svg, :hide_button_while_polling

  def login_path(action)
    helpers.polymorphic_path([ action, record ])
  end

  def button
    render DS::Button.new(
      text: active ? translation("qr_cancel") : translation("qr_login"),
      variant: :outline,
      size: :sm,
      icon: "qr-code",
      type: "button",
      data: {
        action: "trade-republic-qr#toggle",
        trade_republic_qr_target: "button"
      }
    )
  end
end
