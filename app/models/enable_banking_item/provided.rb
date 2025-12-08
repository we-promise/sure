module EnableBankingItem::Provided
  extend ActiveSupport::Concern

  def enable_banking_provider
    return nil unless credentials_configured?

    Provider::EnableBanking.new(
      application_id: application_id,
      client_certificate: client_certificate
    )
  end
end
