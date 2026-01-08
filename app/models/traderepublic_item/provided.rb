module TraderepublicItem::Provided
  extend ActiveSupport::Concern

  def traderepublic_provider
    return nil unless credentials_configured?

    Provider::Traderepublic.new(
      phone_number: phone_number,
      pin: pin
    )
  end
end
