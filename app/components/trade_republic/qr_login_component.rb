# The QR login button and panel, shared by the settings connection card and
# the Accounts page so a connection can log in again from either place.
class TradeRepublic::QrLoginComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def initialize(item:, return_url:, active: false, code_svg: nil)
    @item = item
    @return_url = return_url
    @active = active
    @code_svg = code_svg
  end

  attr_reader :item, :return_url, :active, :code_svg
end
