class TradeRepublic::ConnectionCardComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def self.dom_id_for(item)
    ActionView::RecordIdentifier.dom_id(item, :trade_republic_card)
  end

  # `pin_form_open` shows the PIN login again after a failed attempt.
  def initialize(item:, qr_active: false, qr_code_svg: nil, pin_form_open: false)
    @item = item
    @qr_active = qr_active
    @qr_code_svg = qr_code_svg
    @pin_form_open = pin_form_open && !qr_active
  end

  attr_reader :item, :qr_active, :qr_code_svg, :pin_form_open

  def dom_id
    self.class.dom_id_for(item)
  end

  # Every connection defaults to the same name, and QR logins have no phone
  # number, so the last 4 characters of whichever identifier is available
  # help tell cards apart when disconnecting one of several.
  def identifier_last4
    identifier&.last
  end

  def identifier_text
    masked_identifier(*identifier) if identifier
  end

  # TradeRepublicItem#login_stage decodes the pending login payload on every
  # call, and the template checks the stage several times per card, so cache
  # it for the duration of the render.
  def login_stage
    return @login_stage if defined?(@login_stage)

    @login_stage = item.login_stage
  end

  # While Trade Republic waits for a push approval or an authenticator code,
  # starting another login would replace that one.
  def push_login_in_progress?
    login_stage.in?(%w[waiting_for_approval authenticator_code])
  end

  def pin_login_form_id
    "#{dom_id}_pin_login"
  end

  def status_dot_class
    if item.syncing? then "bg-inverse animate-pulse"
    elsif login_stage == "expired" then "bg-destructive"
    elsif item.pending_login_state.present? || item.needs_login? then "bg-warning"
    elsif item.ready_for_sync? then "bg-success"
    else "bg-surface-inset"
    end
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
end
