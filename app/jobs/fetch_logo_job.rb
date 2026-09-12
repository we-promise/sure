# frozen_string_literal: true

# Background job to fetch and attach logos from domains asynchronously
class FetchLogoJob < ApplicationJob
  queue_as :default

  def perform(account_id, expected_domain = nil)
    account = Account.find_by(id: account_id)
    return unless account
    return unless account.logo_source_auto?
    # Allow fetching if we have a domain OR a provider logo URL
    return unless account.institution_domain.present? || account.provider&.logo_url.present?

    Account::LogoFetcher.new(account, expected_domain: expected_domain).fetch_and_attach
  end
end
