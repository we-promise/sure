class AccountLogoFetchJob < ApplicationJob
  queue_as :low_priority

  PACE_KEY = "account_logo_fetch_pace"
  MAX_SLOT_PROBES = 50

  # Spaces fetches for the iTunes Search API limit: each one claims the next
  # free time slot in the shared cache (Redis in production), so imports, the
  # nightly backfill and single domain changes share one queue. A claim lasts
  # until its slot has passed; a lone domain change usually fetches at once.
  def self.perform_paced(account)
    spacing = AccountLogoBackfillJob::SPACING.to_i
    now = Time.current.to_i
    # The next slot others claimed is only a hint where to start probing.
    first = [ now / spacing, Rails.cache.read(PACE_KEY).to_i ].max
    slot = (first...first + MAX_SLOT_PROBES).find do |candidate|
      Rails.cache.write("#{PACE_KEY}:#{candidate}", true, unless_exist: true, expires_in: (candidate * spacing - now + 60).seconds)
    end
    # A cache that refuses every claim (Redis down) must not hold up the
    # caller, so the fetch goes unpaced.
    return perform_later(account) unless slot

    Rails.cache.write(PACE_KEY, slot + 1, expires_in: 1.day)

    set(wait: [ slot * spacing - now, 0 ].max.seconds).perform_later(account)
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
