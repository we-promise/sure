# Reads the stage of a Trade Republic login in progress, for a connection
# logging in again as well as for a new one that is not created yet.
module TradeRepublicLoginState
  extend ActiveSupport::Concern

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
