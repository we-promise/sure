module IbkrItem::Provided
  extend ActiveSupport::Concern

  def ibkr_provider
    return nil unless credentials_configured?

    Provider::IbkrFlex.new(query_id: query_id, token: token)
  end
end
