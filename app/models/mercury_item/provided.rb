module MercuryItem::Provided
  extend ActiveSupport::Concern

  def mercury_provider
    return nil unless credentials_configured?

    Provider::Mercury.new(token, base_url: effective_base_url)
  end

  def syncer
    MercuryItem::Syncer.new(self)
  end
end
