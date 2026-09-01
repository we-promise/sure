# frozen_string_literal: true

# Background job to fetch and attach logos from domains asynchronously
class FetchLogoJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find_by(id: account_id)
    return unless account
    return unless account.logo_source_auto? && account.institution_domain.present?

    Account::LogoFetcher.new(account).fetch_and_attach
  end
end
