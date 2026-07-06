module OpenBankingIoItem::Provided
  extend ActiveSupport::Concern

  def open_banking_io_provider
    return nil unless credentials_configured?

    Provider::OpenBankingIo.new(
      api_base_url: api_base_url,
      api_key: api_key,
      private_key: private_key
    )
  end

  def syncer
    OpenBankingIoItem::Syncer.new(self)
  end
end
