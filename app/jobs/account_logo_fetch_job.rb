class AccountLogoFetchJob < ApplicationJob
  queue_as :low_priority

  PACE_KEY = "account_logo_fetch_pace"

  # Domain changes usually come one at a time and fetch at once. A bulk save
  # (an import) commits many together, so each further one within a minute
  # waits one more step, as the nightly backfill spaces fetches for the
  # iTunes Search API limit. The counter lives in the shared cache.
  def self.perform_paced(account)
    slot = Rails.cache.increment(PACE_KEY, 1, expires_in: 1.minute).to_i - 1
    set(wait: [ slot, 0 ].max * AccountLogoBackfillJob::SPACING).perform_later(account)
  end

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
