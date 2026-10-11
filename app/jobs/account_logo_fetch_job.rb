class AccountLogoFetchJob < ApplicationJob
  queue_as :low_priority

  def perform(account)
    return unless account.logo_auto_fetchable?
    return if Account::LogoFetcher.new(account).fetch(auto: true)

    # Nothing found for a new domain: the automatic icon of the old one goes,
    # unless an icon or Brandfetch was chosen while the search ran.
    account.with_lock do
      if account.logo_auto_fetchable? && account.logo_auto? && !account.stored_logo?(account.logo_key)
        account.logo.purge_later
        account.touch
      end
    end
  end
end
