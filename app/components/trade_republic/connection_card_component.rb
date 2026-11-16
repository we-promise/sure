class TradeRepublic::ConnectionCardComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

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
    identifier&.last
  end

  def identifier_label
    translation("identifier_#{identifier.first}") if identifier
  end

  # TradeRepublicItem#login_stage decodes the pending login payload on every
  # call, and the template checks the stage several times per card, so cache
  # it for the duration of the render.
  def login_stage
    return @login_stage if defined?(@login_stage)

    @login_stage = item.login_stage
  end

  private

    def identifier
      return @identifier if defined?(@identifier)

      @identifier =
        if (digits = last4(item.phone_number))
          [ :phone, digits ]
        elsif (digits = last4(item.brokerage_account_id.presence || portfolio_account_id))
          [ :account, digits ]
        end
    end

    def portfolio_account_id
      item.trade_republic_accounts.detect { |account| account.kind == "portfolio" }&.trade_republic_account_id
    end

    def last4(value)
      cleaned = value.to_s.delete(" ")
      cleaned.last(4) if cleaned.size >= 4
    end
end
