# The QR login button and panel, shared by the settings connection row and
# the Accounts page so a connection can log in again from either place.
# Given a block, the block replaces the button so a caller can place
# `button` among its own actions; the QR panel always follows it.
class TradeRepublic::QrLoginComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def initialize(item:, return_url:, active: false, code_svg: nil)
    @item = item
    @return_url = return_url
    @active = active
    @code_svg = code_svg
  end

  attr_reader :item, :return_url, :active, :code_svg

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
