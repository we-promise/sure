module BrexItem::Provided
  extend ActiveSupport::Concern

  def brex_provider
    return nil unless credentials_configured?

    base_url = effective_base_url
    return nil unless base_url.present?

    Provider::Brex.new(token.to_s.strip, base_url: base_url)
  end

  def syncer
    BrexItem::Syncer.new(self)
  end
end
