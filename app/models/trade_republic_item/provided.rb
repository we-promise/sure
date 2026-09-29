module TradeRepublicItem::Provided
  extend ActiveSupport::Concern

  def trade_republic_provider(pin: self.pin)
    return nil unless credentials_configured? || pending_login_state.present? || session_configured? || requires_update?

    Provider::TradeRepublicClient.new(
      phone_number: phone_number,
      pin: pin
    )
  end

  def login_method
    return nil if pending_login_state.blank?

    return "qr" if trade_republic_provider&.qr_login?(pending_login_b64: pending_login_state)

    trade_republic_provider&.login_method(pending_login_b64: pending_login_state)
  rescue Provider::TradeRepublicClient::Error
    nil
  end

  def login_stage
    return nil if pending_login_state.blank?

    trade_republic_provider&.login_stage(pending_login_b64: pending_login_state)
  rescue Provider::TradeRepublicClient::LoginExpired
    "expired"
  rescue Provider::TradeRepublicClient::Error
    nil
  end
end
