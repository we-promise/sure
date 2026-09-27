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

  # Every connection defaults to the same name, and QR logins have no phone
  # number, so the last 4 characters of whichever identifier is available
  # help tell cards apart when disconnecting one of several.
  def identifier_last4
    last4(item.phone_number) || last4(portfolio_account_id)
  end

  def translation(key, **options)
    helpers.t("settings.providers.trade_republic_panel.#{key}", **options)
  end

  private

    def portfolio_account_id
      item.trade_republic_accounts.detect { |account| account.kind == "portfolio" }&.trade_republic_account_id
    end

    def last4(value)
      cleaned = value.to_s.delete(" ")
      cleaned.last(4) if cleaned.size >= 4
    end
end
