module TinkoffInvestItem::Provided
  extend ActiveSupport::Concern

  def tinkoff_invest_provider
    return nil unless credentials_configured?

    Provider::TinkoffInvest::PortfolioClient.new(
      api_key: api_key,
      environment: environment,
      base_url: base_url.presence
    )
  end
end
