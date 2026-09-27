class TradeRepublic::ConnectionCardComponent < ApplicationComponent
  def self.dom_id_for(item)
    ActionView::RecordIdentifier.dom_id(item, :trade_republic_card)
  end

  def initialize(item:, open: true, qr_active: false, qr_code_svg: nil)
    @item = item
    @open = open
    @qr_active = qr_active
    @qr_code_svg = qr_code_svg
  end

  attr_reader :item, :open, :qr_active, :qr_code_svg

  def dom_id
    self.class.dom_id_for(item)
  end

  def translation(key, **options)
    helpers.t("settings.providers.trade_republic_panel.#{key}", **options)
  end
end
