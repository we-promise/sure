module TradeRepublicItem::Provided
  extend ActiveSupport::Concern

  include TradeRepublicLoginState

  def trade_republic_provider(pin: self.pin)
    return nil unless credentials_configured? || pending_login_state.present? || session_configured? || requires_update?

    Provider::TradeRepublicClient.new(
      phone_number: phone_number,
      pin: pin,
      device_id: device_id
    )
  end
end
