class TradeRepublic::AccountEditorComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  # `qr_code_svg` belongs to the pending connection whose QR login just
  # started; `new_connection` redisplays a failed attempt to add one.
  def initialize(items: nil, family:, pending_connection: nil, qr_code_svg: nil, new_connection: nil)
    @items = items || family.trade_republic_items.active.ordered.includes(:trade_republic_accounts)
    @family = family
    @pending_connection = pending_connection
    @qr_code_svg = qr_code_svg
    @new_connection = new_connection
  end

  attr_reader :items, :family, :qr_code_svg

  def pending_connection
    return @pending_connection if defined?(@loaded_pending_connection)

    @loaded_pending_connection = true
    @pending_connection ||= family.trade_republic_pending_connections.order(:created_at).last
  end

  def new_connection
    @new_connection ||= family.trade_republic_pending_connections.build
  end

  def qr_login_active?(item)
    item.login_stage == "qr_pending"
  end
end
