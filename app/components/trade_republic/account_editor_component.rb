class TradeRepublic::AccountEditorComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def initialize(items: nil, family:, qr_code_svg: nil, qr_login_auto_poll_item: nil, new_item: nil)
    @items = items || family.trade_republic_items.active.ordered.includes(:trade_republic_accounts)
    @family = family
    @qr_code_svg = qr_code_svg
    @qr_login_auto_poll_item = qr_login_auto_poll_item
    @new_item = new_item
  end

  attr_reader :items, :family

  def new_item
    @new_item ||= family.trade_republic_items.build
  end

  # A collapsed card would hide the QR code, the push notice, the
  # authenticator form or the "accounts discovered" setup CTA, so only
  # healthy, fully linked connections among several start closed.
  def open?(item)
    items.size == 1 || qr_login_active?(item) || item.pending_login_state.present? ||
      !item.good? || setup_cta_visible?(item)
  end

  # Mirrors the card template's condition for the "X accounts discovered —
  # Set up accounts" link: without a configured session the CTA never
  # renders, so unlinked accounts alone are no reason to expand.
  def setup_cta_visible?(item)
    item.session_configured? && item.unlinked_accounts_count.positive?
  end

  def qr_login_active?(item)
    item == @qr_login_auto_poll_item || item.login_stage == "qr_pending"
  end

  def qr_code_svg_for(item)
    @qr_code_svg if item == @qr_login_auto_poll_item
  end
end
