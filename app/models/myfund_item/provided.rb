module MyfundItem::Provided
  extend ActiveSupport::Concern

  def myfund_provider
    return nil unless credentials_configured?

    Provider::Myfund.new(api_key: api_key, portfolio_name: portfolio_name)
  end
end
