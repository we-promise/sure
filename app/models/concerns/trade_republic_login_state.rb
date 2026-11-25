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

  # Sent back by the page showing this login, so a request from a page that
  # still shows an earlier login can be told apart.
  def login_token
    Provider::TradeRepublicClient.login_token(pending_login_state) if pending_login_state.present?
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
