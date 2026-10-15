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

  # An approval request that lapsed leaves the row so the login can start
  # again with a QR code, which needs no PIN.
  def expired?
    pending_connection.pending_login_state.blank? || login_stage == "expired"
  end

  def qr_login?
    login_stage == "qr_pending" || pending_connection.login_method == "qr"
  end

  def phone_last4
    digits = pending_connection.phone_number.to_s.delete(" ")
    digits.last(4) if digits.size >= 4
  end
end
