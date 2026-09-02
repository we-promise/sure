module OpenBankingIoItem::Provided
  extend ActiveSupport::Concern

  # Memoized: building a provider parses the PKCS#8 EC private key, and the adapter, the
  # importer and the item all reach for it independently -- import_latest_open_banking_io_data
  # alone used to build two. Reset whenever the stored credentials change.
  def open_banking_io_provider
    return nil unless credentials_configured?

    @open_banking_io_provider ||= Provider::OpenBankingIo.new(
      api_base_url: api_base_url,
      api_key: api_key,
      private_key: private_key
    )
  end

  def reset_open_banking_io_provider!
    @open_banking_io_provider = nil
  end

  def syncer
    OpenBankingIoItem::Syncer.new(self)
  end
end
