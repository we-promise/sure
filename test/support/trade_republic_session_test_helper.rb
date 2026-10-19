# frozen_string_literal: true

# A stored Trade Republic session whose tr_refresh JWT expires at the given
# time. The header and signature are placeholders; Sure only reads the exp.
module TradeRepublicSessionTestHelper
  def trade_republic_session_blob(expires_at:)
    payload = Base64.urlsafe_encode64(JSON.generate(exp: expires_at.to_i), padding: false)
    JSON.generate("tr_session" => "session", "tr_refresh" => "header.#{payload}.signature")
  end
end
