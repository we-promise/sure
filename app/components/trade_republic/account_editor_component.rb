class TradeRepublic::AccountEditorComponent < ApplicationComponent
  def initialize(items: nil, family:, qr_code_svg: nil, qr_login_auto_poll_item: nil)
    @items = items || family.trade_republic_items.active.ordered
    @family = family
    @qr_code_svg = qr_code_svg
    @qr_login_auto_poll_item = qr_login_auto_poll_item
  end

  attr_reader :items, :family

  def new_item
    @new_item ||= family.trade_republic_items.build
  end

  # A collapsed card would hide the QR code, the push notice or the
  # authenticator form, so only healthy connections among several start closed.
  def open?(item)
    items.size == 1 || qr_login_active?(item) || item.pending_login_state.present? || !item.good?
  end

  def qr_login_active?(item)
    item == @qr_login_auto_poll_item || item.login_stage == "qr_pending"
  end

  def qr_code_svg_for(item)
    @qr_code_svg if item == @qr_login_auto_poll_item
  end

  def translation(key, **options)
    helpers.t("settings.providers.trade_republic_panel.#{key}", **options)
  end
end
