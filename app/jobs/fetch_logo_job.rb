# frozen_string_literal: true

# Background job to fetch and attach logos from domains asynchronously
class FetchLogoJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find_by(id: account_id)
    return unless account
    return unless account.logo_source == "auto" && account.institution_domain.present?

    # Only fetch if we don't already have a logo attached
    return if account.logo.attached?

    # Try to fetch from Brandfetch first if configured
    if Setting.brand_fetch_client_id.present?
      logo_url = account.brandfetch_logo_url
      if logo_url.present?
        fetcher = LogoFetcherService.new(account: account, url: logo_url)
        fetcher.fetch_and_attach
        # Only return if we successfully attached a logo
        return if account.logo.attached?
      end
    end

    # Fallback: try to fetch favicon from DuckDuckGo
    favicon = account.favicon_url
    if favicon.present?
      LogoFetcherService.new(account: account, url: favicon).fetch_and_attach
    end
  end
end
