# The QR login button and panel, shared by the settings connection row and
# the Accounts page so a connection can log in again from either place.
# Given a block, the block replaces the button so a caller can place
# `button` among its own actions; the QR panel always follows it.
class TradeRepublic::QrLoginComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  # `record` is the connection logging in again or the pending connection
  # of a new one; both answer the same login routes.
  def initialize(record:, return_url:, active: false, code_svg: nil)
    @record = record
    @return_url = return_url
    @active = active
    @code_svg = code_svg
  end

  attr_reader :record, :return_url, :active, :code_svg

  def login_path(action)
    helpers.polymorphic_path([ action, record ])
  end

  # `data` lets the row's own controllers find the button too.
  def button(hidden: false, data: {})
    render DS::Button.new(
      text: active ? translation("qr_cancel") : translation("qr_login"),
      variant: :outline,
      size: :sm,
      icon: "qr-code",
      type: "button",
      hidden: hidden,
      data: {
        action: "trade-republic-qr#toggle",
        trade_republic_qr_target: "button"
      }.merge(data)
    )
  end
end
