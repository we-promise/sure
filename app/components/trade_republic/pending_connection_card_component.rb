# A new Trade Republic connection while its first login waits for approval.
class TradeRepublic::PendingConnectionCardComponent < ApplicationComponent
  include TradeRepublic::PanelTranslatable

  def initialize(pending_connection:, qr_code_svg: nil)
    @pending_connection = pending_connection
    @qr_code_svg = qr_code_svg
  end

  attr_reader :pending_connection, :qr_code_svg

  def dom_id
    ActionView::RecordIdentifier.dom_id(pending_connection)
  end

  # Decoding the pending login is not free and the template asks several
  # times, so read it once per render.
  def login_stage
    return @login_stage if defined?(@login_stage)

    @login_stage = pending_connection.login_stage
  end

  # TradeRepublicPendingConnection#lapsed?, with the stage read above.
  def expired?
    pending_connection.pending_login_state.blank? || login_stage == "expired"
  end

  def identifier_text
    masked_identifier(:phone, last4(pending_connection.phone_number))
  end
end
